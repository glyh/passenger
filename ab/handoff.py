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
    _bring_to_front(page)
    notify.select().notify("Agent browser needs you", f"{message}\n{how}")
    print(f"   {how}", file=sys.stderr)
    print(f"   waiting up to {timeout_s}s...", file=sys.stderr)

    try:
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            time.sleep(_POLL_INTERVAL_S)
            resolved = _recheck(page, extractor)
            if resolved is not None:
                print(f"   resolved ({resolved.word_count} words)\n",
                      file=sys.stderr)
                return resolved
        print("   timed out waiting for you\n", file=sys.stderr)
        raise HandoffTimeout(name, timeout_s)
    finally:
        if was_hidden:
            presenter.dismiss()


def _recheck(page: Any, extractor: Extractor) -> Extraction | None:
    """One poll. None means the signature still matches (or mid-navigation)."""
    try:
        extraction = extractor(page)
        signatures = registry.active()
        page_probe = probe_mod.probe(page, extraction, signatures)
        if classify(page_probe, signatures) is None:
            return extraction
    except Exception:
        return None  # navigating; try again next tick
    return None


def _bring_to_front(page: Any) -> None:
    try:
        page.bring_to_front()
    except Exception:
        pass


__all__ = ["wait_for_human", "Extractor"]
