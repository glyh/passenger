"""Turning a loaded page into text.

Two strategies, because pages come in two shapes:

  article  boilerplate removal (trafilatura). Right for documents.
  dom      visible text off the live DOM, minus obvious furniture. Noisier,
           but it is the only thing that keeps a listing's content.

This file used to say `dom` exists because trafilatura cannot see a JS app.
That is wrong: `page.content()` is the *rendered* DOM, so trafilatura is handed
the same nodes -- it sees a listing and discards it as boilerplate, which every
readability-family extractor does (measured against defuddle in ticket 009).
The difference `dom` makes is one of judgement, not of visibility.

`auto` picks by measuring rather than guessing from the URL. Note that on every
page measured so far, `article` has won -- see README. `dom` is an escape
hatch, not a validated fix.
"""
import re
from typing import Any, assert_never

import trafilatura

from .models import Extraction, ExtractMode

_STRIP = ("script, style, noscript, template, svg, nav, header, footer, aside, "
          "[role=navigation], [role=banner], [role=contentinfo], "
          "[aria-hidden=true], [hidden]")

_ROOTS = ("main", "[role=main]", "article", "#content", "#main", "body")

# Below this share of the page's visible words, the article extractor is
# assumed to have thrown away real content rather than boilerplate.
_ARTICLE_YIELD_FLOOR = 0.35
_MIN_COMPARABLE_WORDS = 40

_DOM_JS = """
([stripSel, roots]) => {
  const doc = document.cloneNode(true);
  doc.querySelectorAll(stripSel).forEach(e => e.remove());
  let root = null;
  for (const sel of roots) {
    const el = doc.querySelector(sel);
    if (el && (el.innerText || '').trim().length > 40) { root = el; break; }
  }
  root = root || doc.body;
  const txt = (root.innerText || '').trim();
  if (txt.length > 40) return txt;
  for (const sel of roots) {
    const live = document.querySelector(sel);
    if (live && (live.innerText || '').trim().length > 40) return live.innerText.trim();
  }
  return (document.body.innerText || '').trim();
}
"""


def article_text(html: str, url: str | None = None) -> str:
    """Pure: HTML in, markdown out."""
    out = trafilatura.extract(
        html, url=url, output_format="markdown",
        include_links=True, include_tables=True, favor_recall=True,
    )
    return (out or "").strip()


def tidy(raw: str) -> str:
    """Pure: collapse the blank runs and stray whitespace innerText leaves."""
    lines = [re.sub(r"[ \t ]+", " ", line).strip()
             for line in raw.splitlines()]
    kept: list[str] = []
    pending_blank = False
    for line in lines:
        if not line:
            pending_blank = True
            continue
        if pending_blank and kept:
            kept.append("")
        pending_blank = False
        kept.append(line)
    return "\n".join(kept).strip()


def dom_text(page: Any) -> str:
    """Shell: read visible text off the live page."""
    try:
        raw = page.evaluate(_DOM_JS, [_STRIP, list(_ROOTS)])
    except Exception:
        raw = page.inner_text("body")
    return tidy(raw)


def choose(article: str, dom: str) -> Extraction:
    """Pure: the `auto` decision, isolated so it can be tested without a page."""
    article_words, dom_words = len(article.split()), len(dom.split())
    if dom_words >= _MIN_COMPARABLE_WORDS:
        if article_words < _ARTICLE_YIELD_FLOOR * dom_words:
            return Extraction(text=dom, mode_used=ExtractMode.DOM)
    return Extraction(text=article, mode_used=ExtractMode.ARTICLE)


def extract(page: Any, mode: ExtractMode) -> Extraction:
    """Shell: gather what the chosen mode needs, then decide."""
    match mode:
        case ExtractMode.DOM:
            return Extraction(text=dom_text(page), mode_used=ExtractMode.DOM)
        case ExtractMode.ARTICLE:
            return Extraction(text=article_text(page.content(), page.url),
                              mode_used=ExtractMode.ARTICLE)
        case ExtractMode.AUTO:
            return choose(article_text(page.content(), page.url), dom_text(page))
        case _ as unreachable:
            assert_never(unreachable)
