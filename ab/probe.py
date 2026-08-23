"""Imperative shell: measuring a live page.

Selector evaluation and screenshots need a browser; the decisions made from
them do not. This module is the boundary between those two worlds.
"""
import time
from typing import Any

from .detect import selectors_of
from .models import PageProbe

_MATCH_JS = "sels => sels.filter(s => { try { return !!document.querySelector(s); }"
_MATCH_JS += " catch (e) { return false; } })"


def probe(page: Any) -> PageProbe:
    """Measure everything detection needs, in as few round trips as possible.

    The extraction used to be handed in, for a `word_count` no rule had read
    since ticket 005. Ticket 021 dropped the field, and with it this
    function's one dependency on how the caller chose to read the page.

    The signature table used to be handed in as well, from a registry that
    could add learned rules to it. Ticket 019 removed the learning, so there
    is one table and `selectors_of` reads it directly.
    """
    try:
        title = page.title()
    except Exception:
        title = ""
    selectors = selectors_of()
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
