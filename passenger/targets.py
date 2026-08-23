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
"""
import json
import time
import urllib.request
from typing import Any

from websockets.sync.client import connect

from .config import CDP_URL
from .models import Target

# How long a page gets to answer a question its renderer answers instantly when
# it is healthy. Generous by two orders of magnitude, because the cost of being
# wrong is stopping a navigation someone wanted.
PROBE_DEADLINE_S = 3.0


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


def unstick(deadline_s: float = PROBE_DEADLINE_S) -> tuple[Target, ...]:
    """Stop the pending navigation on every page that has stopped answering.

    Returns the pages that were stuck, which is also the answer to "was there
    anything wrong with the browser, or is the attach failing for some other
    reason". An empty result means the hang is not this.
    """
    stuck: list[Target] = []
    for page in pages():
        if not page.websocket_url:
            continue  # nothing to ask; Chrome withholds a socket for its own UI
        if _unstick_one(page, deadline_s):
            stuck.append(page)
    return tuple(stuck)


def _unstick_one(page: Target, deadline_s: float) -> bool:
    """True if this page was stuck (and has now been told to stop loading)."""
    try:
        with connect(page.websocket_url, open_timeout=deadline_s) as socket:
            if _call(socket, 1, "Page.getFrameTree", deadline_s) is not None:
                return False
            _call(socket, 2, "Page.stopLoading", deadline_s)
            return True
    except Exception:
        # A target that cannot even be connected to is not one we can rescue,
        # and guessing at it would risk stopping a navigation that is fine.
        return False


def _call(socket: Any, ident: int, method: str,
          deadline_s: float) -> dict[str, Any] | None:
    """One CDP command. None means the renderer never answered.

    Replies have to be picked out of the event stream by id: a page under
    navigation emits lifecycle events continuously, and reading the next frame
    would read one of those instead of the answer.
    """
    socket.send(json.dumps({"id": ident, "method": method, "params": {}}))
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
