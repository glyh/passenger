"""Imperative shell: Chrome's targets, over the endpoints the browser answers.

Everything here speaks to the CDP *HTTP* endpoint and to a page's own
websocket, deliberately going around patchright. That is the whole point: when
one tab is stuck mid-navigation, patchright cannot attach at all -- it
initialises every page that is already open and waits for all of them -- so the
recovery path cannot be built on the thing that is stuck.

Measured, on a tab left mid-navigation: `Page.getFrameTree` gets no reply at
all, where a healthy tab answers in under 10ms. `Page.stopLoading` on that same
tab is answered immediately, and the tab answers everything again afterwards.
So a stuck tab is *unstuck*, not closed: whatever document it already had --
the page a human was reading, most often -- survives.

There is a second way to hold the attach open, and it looks like the opposite
from here (ticket 042). A tab created *at* a URL -- a popup, a target=_blank a
human clicked, a session restore -- never commits a document if that URL never
answers. Its renderer has nothing to be busy with, so it answers `getFrameTree`
in under 10ms and reads as healthy, while the attach hangs just as hard. What
gives it away is the answer rather than the silence: the frame's URL is the
empty string, which is Chrome for "no document here at all".
"""
import json
import time
import urllib.request
from collections import Counter
from typing import Any

from websockets.sync.client import connect

from .config import CDP_URL
from .models import Target, Wedge

# How long a page gets to answer a question its renderer answers instantly when
# it is healthy. Generous by two orders of magnitude, because the cost of being
# wrong is stopping a navigation someone wanted.
PROBE_DEADLINE_S = 3.0

# The same question asked for a report rather than for a rescue. Shorter,
# because `status` walks every tab and nothing is freed on the strength of the
# answer: a page that misses this deadline is named, not acted on.
STATUS_DEADLINE_S = 1.0

# Chrome's way of saying a frame holds no document. Not "about:blank", which is
# a document -- an empty string, which is the absence of one.
NO_DOCUMENT = ""


def listing() -> tuple[Target, ...]:
    """Every target Chrome currently holds, browser UI and workers included."""
    with urllib.request.urlopen(f"{CDP_URL}/json/list", timeout=5) as response:
        return parse(response.read().decode())


def parse(payload: str) -> tuple[Target, ...]:
    """Pure: the endpoint's JSON as models. Unknown fields are dropped."""
    raw: list[dict[str, Any]] = json.loads(payload)
    return tuple(Target.model_validate(entry) for entry in raw)


def pages() -> tuple[Target, ...]:
    return tuple(target for target in listing() if target.is_page)


def stuck(deadline_s: float = PROBE_DEADLINE_S
          ) -> tuple[tuple[Target, Wedge], ...]:
    """Every page that is holding the attach open, and which way it is doing it.

    Read-only: this is the half `status` can call. Freeing them is `unstick`.
    """
    found: list[tuple[Target, Wedge]] = []
    for page in pages():
        if not page.websocket_url:
            continue  # nothing to ask; Chrome withholds a socket for its own UI
        wedge = _diagnose(page, deadline_s)
        if wedge is not None:
            found.append((page, wedge))
    return tuple(found)


def unstick(deadline_s: float = PROBE_DEADLINE_S) -> tuple[Target, ...]:
    """Free every page that is holding the attach open, each its own way.

    Returns the pages that were stuck, which is also the answer to "was there
    anything wrong with the browser, or is the attach failing for some other
    reason". An empty result means the hang is not this.

    Called only after an attach has already timed out, and that is what makes
    the UNCOMMITTED remedy affordable. A tab that has yet to commit a document
    is indistinguishable from a tab on a merely slow host -- both are waiting
    on headers, and no field separates them -- so this does stop a navigation
    someone may have wanted. What it has to weigh against is that the same
    navigation has been failing every call in every lane for the whole attach
    timeout, and that re-navigating is cheap where a bricked tool is not.
    """
    freed: list[Target] = []
    for page, wedge in stuck(deadline_s):
        if _free(page, wedge, deadline_s):
            freed.append(page)
    return tuple(freed)


def stuck_summary(deadline_s: float = STATUS_DEADLINE_S) -> str:
    """One line naming the wedged tabs, for `status`. "none" when there are none.

    A tab that has been navigating for minutes is the thing a human staring at
    a tool that will not answer would want named, and until now nothing said
    it: `status` reported a tab count, and a wedged tab counts the same as a
    working one. A count per wedge and no more -- which tab, in whose lane, is
    a listing, and a lane's tabs are nobody else's business (ticket 040).

    Counting UNCOMMITTED here counts a tab that is merely mid-navigation, which
    is honest: it is navigating, and this says so rather than ruling on whether
    it is stuck. Nothing is freed on the strength of it.
    """
    counts = Counter(wedge for _, wedge in stuck(deadline_s))
    if not counts:
        return "none"
    return ", ".join(f"{counts[wedge]} {wedge.value}"
                     for wedge in Wedge if counts[wedge])


def _diagnose(page: Target, deadline_s: float) -> Wedge | None:
    """Ask one page to describe itself. None means it is fine."""
    try:
        with connect(page.websocket_url, open_timeout=deadline_s) as socket:
            return verdict(_call(socket, 1, "Page.getFrameTree", deadline_s))
    except Exception:
        # A target that cannot even be connected to is not one we can rescue,
        # and guessing at it would risk stopping a navigation that is fine.
        return None


def verdict(reply: dict[str, Any] | None) -> Wedge | None:
    """Pure: what one `Page.getFrameTree` answer says about the tab.

    `None` for the reply means the renderer never answered at all.
    """
    if reply is None:
        return Wedge.SILENT
    if "result" not in reply:
        # An error reply is still an answer, so the renderer is alive -- but it
        # is not one this can read a frame out of. Conservative on purpose:
        # the remedies here stop navigations, and a reply nobody planned for is
        # a bad reason to stop one.
        return None
    frame = reply["result"].get("frameTree", {}).get("frame", {})
    if frame.get("url", NO_DOCUMENT) == NO_DOCUMENT:
        return Wedge.UNCOMMITTED
    return None


# What frees each wedge, measured one against the other on a server that
# accepts and then answers nothing. Neither remedy works on the other's tab.
_REMEDY: dict[Wedge, tuple[str, dict[str, Any]]] = {
    Wedge.SILENT: ("Page.stopLoading", {}),
    Wedge.UNCOMMITTED: ("Page.navigate", {"url": "about:blank"}),
}


def _free(page: Target, wedge: Wedge, deadline_s: float) -> bool:
    """Apply this wedge's remedy. True if the page took it."""
    method, params = _REMEDY[wedge]
    try:
        with connect(page.websocket_url, open_timeout=deadline_s) as socket:
            _call(socket, 1, method, deadline_s, params)
            return True
    except Exception:
        return False


def _call(socket: Any, ident: int, method: str, deadline_s: float,
          params: dict[str, Any] | None = None) -> dict[str, Any] | None:
    """One CDP command. None means the renderer never answered.

    Replies have to be picked out of the event stream by id: a page under
    navigation emits lifecycle events continuously, and reading the next frame
    would read one of those instead of the answer.
    """
    socket.send(json.dumps({"id": ident, "method": method,
                            "params": params or {}}))
    end = time.time() + deadline_s
    while True:
        remaining = end - time.time()
        if remaining <= 0:
            return None
        try:
            message: dict[str, Any] = json.loads(socket.recv(timeout=remaining))
        except TimeoutError:
            return None
        if message.get("id") == ident:
            return message


def browser_socket() -> str:
    """The *browser* process's own websocket, which no page owns.

    `/json/list` describes pages and hands out a socket per page; the browser
    endpoint is only in `/json/version`, and it is the one that can answer
    `Target.getTargets` -- the question with `openerId` in the reply.
    """
    with urllib.request.urlopen(f"{CDP_URL}/json/version", timeout=5) as response:
        payload: dict[str, Any] = json.loads(response.read().decode())
    return str(payload.get("webSocketDebuggerUrl", ""))


def openers(deadline_s: float = PROBE_DEADLINE_S) -> dict[str, str]:
    """Which tab opened which, as Chrome itself records it.

    A page that calls `window.open`, or a link with `target="_blank"`, creates
    a target nobody asked this tool for. Attributing it to the lane that
    caused it needs a record of causation, and Chrome has one: `openerId` on
    `Target.getTargets`. Guessing from timing or URL was the alternative, and
    it is the kind of heuristic this project keeps deleting.

    Not available from `/json/list`, which is why this goes to the websocket.
    An empty map on any failure: adoption is an improvement over leaving a tab
    unowned, never a precondition for the caller's actual work.
    """
    try:
        socket_url = browser_socket()
        if not socket_url:
            return {}
        with connect(socket_url, open_timeout=deadline_s) as socket:
            reply = _call(socket, 1, "Target.getTargets", deadline_s)
    except Exception:
        return {}
    if reply is None:
        return {}
    infos = reply.get("result", {}).get("targetInfos", [])
    return {info["targetId"]: info["openerId"] for info in infos
            if info.get("type") == "page" and info.get("openerId")}


def close(target_id: str) -> bool:
    """Close one target through the browser process. True if it answered.

    Goes around patchright for the same reason the rest of this module does:
    tab bookkeeping must keep working when a renderer does not, and an attach
    that initialises every open tab is a strange price to pay for closing one.
    """
    try:
        with urllib.request.urlopen(f"{CDP_URL}/json/close/{target_id}",
                                    timeout=5) as response:
            return bool(response.status == 200)
    except Exception:
        return False
