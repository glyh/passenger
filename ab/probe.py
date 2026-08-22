"""Imperative shell: measuring a live page.

Selector evaluation and screenshots need a browser; the decisions made from
them do not. This module is the boundary between those two worlds.
"""
import json
import time
from pathlib import Path
from typing import Any

from .config import REPORTS_DIR
from .detect import selectors_of
from .models import Evidence, Extraction, PageProbe, Signature

_IFRAME_JS = "els => els.map(e => e.src).filter(Boolean).slice(0, 10)"
_PROMPT_JS = ("els => els.map(e => (e.innerText||'').trim())"
              ".filter(t => t && t.length < 120).slice(0, 15)")
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


def capture_evidence(page: Any, page_probe: PageProbe, stamp: int) -> Evidence:
    """Dump what a human -- or a model -- needs to classify a novel blocker."""
    REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    screenshot: Path | None = REPORTS_DIR / f"{stamp}.png"
    try:
        page.screenshot(path=str(screenshot))
    except Exception:
        screenshot = None

    evidence = Evidence(
        probe=page_probe,
        iframe_srcs=tuple(_safe_eval(page, "iframe", _IFRAME_JS)),
        visible_text=tuple(_safe_eval(
            page, "h1, h2, button, [role=button], label", _PROMPT_JS)),
        screenshot=screenshot,
    )
    (REPORTS_DIR / f"{stamp}.json").write_text(
        evidence.model_dump_json(indent=2))
    return evidence


def now() -> int:
    """Clock access, isolated so the core stays deterministic."""
    return int(time.time())


def _safe_eval(page: Any, selector: str, script: str) -> list[str]:
    try:
        found: list[str] = page.eval_on_selector_all(selector, script)
    except Exception:
        return []
    return found
