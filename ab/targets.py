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
