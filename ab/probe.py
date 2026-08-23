"""Imperative shell: measuring a live page.

Selector evaluation and screenshots need a browser; the decisions made from
them do not. This module is the boundary between those two worlds.
"""
import time
from typing import Any

from .detect import selectors_of
from .models import Extraction, PageProbe, Signature

_MATCH_JS = "sels => sels.filter(s => { try { return !!document.querySelector(s); }"
_MATCH_JS += " catch (e) { return false; } })"


def probe(page: Any, extraction: Extraction,
          signatures: tuple[Signature, ...]) -> PageProbe:
    """Measure everything detection needs, in as few round trips as possible."""
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
                     word_count=extraction.word_count,
                     matched_selectors=frozenset(hits))


def now() -> int:
    """Clock access, isolated so the core stays deterministic."""
    return int(time.time())
