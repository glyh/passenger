"""Imperative shell: asking a human to solve what the agent must not.

Nothing here tries to solve a challenge. Solver services get profiles burned
and make the browser *more* detectable; a human solving it once into a
persistent profile is both more robust and the defensible version of this.
"""
import subprocess
import sys
import time
from typing import Any, Callable

from . import probe as probe_mod
from . import registry, window
from .config import HANDOFF_TIMEOUT_S
from .detect import blocker_name, classify, is_novel, propose_signature
from .errors import HandoffTimeout, WindowError
from .models import Blocker, Evidence, Extraction, Signature

_POLL_INTERVAL_S = 2

Extractor = Callable[[Any], Extraction]


def record_novel(page: Any, blocker: Blocker) -> tuple[Evidence, Signature | None]:
    """Capture what a novel blocker looked like and propose a rule for it.

    Runs whether or not a handoff follows: a suppressed handoff is exactly when
    you most want to know what you hit.
    """
    stamp = probe_mod.now()
    evidence = probe_mod.capture_evidence(page, blocker.probe, stamp)
    proposal = propose_signature(evidence, stamp)
    if proposal is not None:
        registry.remember(proposal)
    return evidence, proposal


def wait_for_human(page: Any, blocker: Blocker, extractor: Extractor,
                   min_words: int,
                   timeout_s: int = HANDOFF_TIMEOUT_S) -> Extraction:
    """Summon the window, ask, and poll until the block clears.

    Raises HandoffTimeout rather than returning None -- a caller that forgets
    to check would otherwise print an empty document as if it were content.
    """
    name = blocker_name(blocker)
    message = f"[{name}] needs you: {blocker.probe.url}"
    print(f"\n!! {message}", file=sys.stderr)

    backend = window.select()
    was_hidden = not backend.visible()
    try:
        backend.set_visible(True)
    except WindowError as exc:
        print(f"   {exc.message} -- {exc.detail}", file=sys.stderr)
    _bring_to_front(page)
    _notify(message)
    print(f"   solve it in the Chrome window; waiting up to {timeout_s}s...",
          file=sys.stderr)

    try:
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            time.sleep(_POLL_INTERVAL_S)
            resolved = _recheck(page, extractor, min_words)
            if resolved is not None:
                print(f"   resolved ({resolved.word_count} words)\n",
                      file=sys.stderr)
                return resolved
        print("   timed out waiting for you\n", file=sys.stderr)
        raise HandoffTimeout(name, timeout_s)
    finally:
        if was_hidden:
            backend.set_visible(False)


def _recheck(page: Any, extractor: Extractor, min_words: int) -> Extraction | None:
    """One poll. None means still blocked (or mid-navigation)."""
    try:
        extraction = extractor(page)
        signatures = registry.active()
        page_probe = probe_mod.probe(page, extraction, signatures)
        if classify(page_probe, signatures, min_words) is None:
            return extraction
    except Exception:
        return None  # navigating; try again next tick
    return None


def _bring_to_front(page: Any) -> None:
    try:
        page.bring_to_front()
    except Exception:
        pass


def _notify(message: str) -> None:
    subprocess.run(
        ["notify-send", "-u", "critical", "Agent browser needs you", message],
        check=False)


__all__ = ["record_novel", "wait_for_human", "is_novel", "Extractor"]
