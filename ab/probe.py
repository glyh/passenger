"""Imperative shell: measuring a live page.

Selector evaluation and screenshots need a browser; the decisions made from
them do not. This module is the boundary between those two worlds.
"""
import time
from typing import Any

from .detect import selectors_of
from .models import PageProbe, Signature

_MATCH_JS = "sels => sels.filter(s => { try { return !!document.querySelector(s); }"
_MATCH_JS += " catch (e) { return false; } })"


def probe(page: Any, signatures: tuple[Signature, ...]) -> PageProbe:
    """Measure everything detection needs, in as few round trips as possible.

    The extraction used to be handed in, for a `word_count` no rule had read
    since ticket 005. Ticket 021 dropped the field, and with it this
    function's one dependency on how the caller chose to read the page.
    """
    try:
        title = page.title()
    except Exception:
        title = ""
    selectors = selectors_of(signatures)
    hits: list[str]
    try:
        hits = page.evaluate(_MATCH_JS, list(selectors))
    except Exception:
        hits = []
    return PageProbe(url=page.url, title=title,
                     matched_selectors=frozenset(hits))


def now() -> int:
    """Clock access, isolated so the core stays deterministic."""
    return int(time.time())
