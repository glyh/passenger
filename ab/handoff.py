"""Imperative shell: asking a human to solve what the agent must not.

Nothing here tries to solve a challenge. Solver services get profiles burned
and make the browser *more* detectable; a human solving it once into a
persistent profile is both more robust and the defensible version of this.
"""
import sys
import time
from typing import Any, Callable

from . import probe as probe_mod
from . import notify, present, registry
from .config import HANDOFF_TIMEOUT_S
from .detect import classify
from .errors import HandoffTimeout, WindowError
from .models import Blocker, Extraction

_POLL_INTERVAL_S = 2

Extractor = Callable[[Any], Extraction]


def wait_for_human(page: Any, blocker: Blocker, extractor: Extractor,
                   timeout_s: int = HANDOFF_TIMEOUT_S) -> Extraction:
    """Summon the window, ask, and poll until the block clears.

    Raises HandoffTimeout rather than returning None -- a caller that forgets
    to check would otherwise print an empty document as if it were content.
    """
    name = blocker.signature.name
    message = f"[{name}] needs you: {blocker.probe.url}"

    presenter = present.select()
    was_hidden = not presenter.presented()
    try:
        how = presenter.present()
    except WindowError as exc:
        how = f"{exc.message} -- {exc.detail}"
    bring_to_front(page)
    notify.select().notify("Agent browser needs you", f"{message}\n{how}")
    print(f"   {how}", file=sys.stderr)
    print(f"   waiting up to {timeout_s}s...", file=sys.stderr)

    try:
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            time.sleep(_POLL_INTERVAL_S)
            resolved = _recheck(page, extractor)
            if resolved is not None:
                print(f"   resolved ({resolved.char_count} characters)\n",
                      file=sys.stderr)
                return resolved
        print("   timed out waiting for you\n", file=sys.stderr)
        raise HandoffTimeout(name, timeout_s)
    finally:
        if was_hidden:
            presenter.dismiss()


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


def _recheck(page: Any, extractor: Extractor) -> Extraction | None:
    """One poll. None means the signature still matches (or mid-navigation)."""
    try:
        extraction = extractor(page)
        signatures = registry.active()
        page_probe = probe_mod.probe(page, signatures)
        if classify(page_probe, signatures) is None:
            return extraction
    except Exception:
        return None  # navigating; try again next tick
    return None


def bring_to_front(page: Any) -> None:
    try:
        page.bring_to_front()
    except Exception:
        pass


__all__ = ["wait_for_human", "wait_for_dismissal", "bring_to_front",
           "Extractor"]
