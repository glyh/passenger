"""Imperative shell: asking a human to solve what the agent must not.

Nothing here tries to solve a challenge. Solver services get profiles burned
and make the browser *more* detectable; a human solving it once into a
persistent profile is both more robust and the defensible version of this.
"""
import sys
import time
from typing import Any

from . import probe as probe_mod
from . import notify, present
from .config import HANDOFF_TIMEOUT_S
from .detect import classify
from .errors import HandoffTimeout, WindowError

_POLL_INTERVAL_S = 2


def wait_until_unblocked(page: Any, timeout_s: int = HANDOFF_TIMEOUT_S) -> str:
    """Poll until the vendor's signature stops matching, and say what ended it.

    The other half of asking for a human. `wait_for_dismissal` waits on the
    human saying they are done; this waits on the *page* saying the wall is
    gone, which is a different fact and a stronger one -- a human can close the
    viewer without having solved anything.

    This is a measurement, not a judgement, and only because the signature
    table is fixed (ticket 038): a vendor either serves that markup or does
    not. It used to live inside `fetch`, re-extracting the page on every tick
    to hand the content back in the same call. `fetch` is gone (ticket 046) and
    so is the extraction -- what is polled now is the signature alone, and the
    caller reads the page itself afterwards.
    """
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        time.sleep(_POLL_INTERVAL_S)
        if _clear(page):
            waited = int(timeout_s - (deadline - time.time()))
            return f"wall cleared after {waited}s"
    return f"still blocked after {timeout_s}s"


def wait_for_dismissal(presenter: present.Presenter, timeout_s: int) -> str:
    """Block until the human closes the viewer, and say what ended the wait.

    The deliberate half of asking for a human (ticket 018). Nothing here looks
    at the page: with no signature to re-check there is no fact this side can
    read that says "solved", and every proxy for one -- the URL changed, the
    word count moved -- is the guess ticket 005 deleted, made again on weaker
    evidence. The caller recognised the wall well enough to ask for a human;
    it can read the page afterwards and see whether the wall is gone.

    So the only thing waited on is the human saying they are done, which they
    say by closing the window. A presenter that cannot see its own window is
    told to poll instead of being handed a wait that would return instantly.
    """
    if not presenter.observes_presence:
        return (f"cannot wait on the {presenter.name.value} presenter: it "
                "cannot see whether the viewer is open. Poll the tab with "
                "`script` instead")
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        time.sleep(_POLL_INTERVAL_S)
        if not presenter.presented():
            waited = int(timeout_s - (deadline - time.time()))
            return f"viewer closed after {waited}s"
    return f"still open after {timeout_s}s"


def _clear(page: Any) -> bool:
    """One poll. False means the signature still matches, or mid-navigation."""
    try:
        return classify(probe_mod.probe(page)) is None
    except Exception:
        return False  # navigating; try again next tick


def bring_to_front(page: Any) -> None:
    try:
        page.bring_to_front()
    except Exception:
        pass


__all__ = ["wait_until_unblocked", "wait_for_dismissal", "bring_to_front"]
