"""Turning a loaded page into text.

Two strategies, because pages come in two shapes:

  article  boilerplate removal (trafilatura). Right for documents.
  dom      visible text off the live DOM, minus obvious furniture. Noisier,
           but it is the only thing that keeps a listing's content.

Both keep links, rendered inline as `[label](url)` against the document's own
URL. `dom` did not, and a listing read through it was forty labels pointing
nowhere -- see ticket 007. Targets are passed through whole: on a page whose
ids are opaque and whose query string is a signed capability, a tidied-up URL
is not the same URL.

Both also emit markdown structure: headings, list markers and fenced code.
`dom` emitted none of it until ticket 025, which measured the difference on
documentation -- 34 fenced blocks against trafilatura's 8 on one asyncio page,
where before there were none and a code sample was indistinguishable from the
prose around it.

This file used to say `dom` exists because trafilatura cannot see a JS app.
That is wrong: `page.content()` is the *rendered* DOM, so trafilatura is handed
the same nodes -- it sees a listing and discards it as boilerplate, which every
readability-family extractor does (measured against defuddle in ticket 009).
The difference `dom` makes is one of judgement, not of visibility.

There is no third mode that picks between them. `auto` did, by measuring both
extractions and comparing their word counts, and ticket 011 found that every
signal available to it was a proxy for the page's *type* -- which is not in
the text. Ticket 021 removed it and made `mode` required at both doors, so a
page read the wrong way is now a caller's decision rather than this side's
silent one.
"""
import re
from importlib import resources
from typing import Any, assert_never

import trafilatura

from .models import Extraction, ExtractMode

_STRIP = ("script, style, noscript, template, svg, nav, header, footer, aside, "
          "[role=navigation], [role=banner], [role=contentinfo], "
          "[aria-hidden=true], [hidden]")

# Candidate containers, most specific first. `body` is not among them: it
# matches on every page and holds everything, so as a candidate it could never
# lose. It is the fallback, and the walker names it as one.
_ROOTS = ("main", "[role=main]", "article", "#content", "#main")

# Read once, at import, which is exactly what the string literal this replaces
# did. Reading per call would make the walker hot-reloadable and make *which
# code ran* unanswerable, which is worse than the stale-server problem it would
# be papering over; a running server is restarted after an edit (ticket 034).
#
# It also closes the hole the move opened. A data file can go missing from a
# wheel in a way `pythonImportsCheck` would not otherwise see -- the import
# succeeds and the first fetch fails -- but both entry points import this
# module, so a missing `walker.js` now fails the package build instead.
_DOM_JS = resources.files("passenger").joinpath("walker.js").read_text(encoding="utf-8")


def article_text(html: str, url: str | None = None) -> str:
    """Pure: HTML in, markdown out."""
    out = trafilatura.extract(
        html, url=url, output_format="markdown",
        include_links=True, include_tables=True, favor_recall=True,
    )
    return (out or "").strip()


def tidy(raw: str) -> str:
    """Pure: collapse the blank runs and stray whitespace innerText leaves.

    A fenced block passes through verbatim. Collapsing runs of spaces is right
    for prose read off the DOM and wrong for the one thing whose indentation
    *is* its meaning: the walker has always kept `PRE` whitespace, and this
    function threw it away again line by line, which did not show until the
    fence made the block worth reading.
    """
    kept: list[str] = []
    pending_blank = False
    in_fence = False
    for line in raw.splitlines():
        if line.strip() == "```":
            if not in_fence and pending_blank and kept:
                kept.append("")
            pending_blank = False
            in_fence = not in_fence
            kept.append("```")
            continue
        if in_fence:
            kept.append(line.rstrip())
            continue
        line = re.sub(r"[ \t ]+", " ", line).strip()
        if not line:
            pending_blank = True
            continue
        if pending_blank and kept:
            kept.append("")
        pending_blank = False
        kept.append(line)
    return "\n".join(kept).strip()


def dom_text(page: Any) -> str:
    """Shell: read visible text, links included, off the live page.

    The fallback is for a page that cannot answer -- a wedged renderer (ticket
    012), a navigation mid-flight, a closed target -- and degrading to
    `inner_text` gets the caller something rather than an error. What it must
    not do is stand in for a bug in `walker.js`, because `inner_text("body")`
    usually contains everything an assertion looks for: measured in ticket 034,
    a walker replaced by a syntax error left two of this module's three tests
    passing. `tests/test_walker.py` poisons `inner_text` so the fallback is
    unreachable there and a broken walker fails loudly.
    """
    try:
        raw = page.evaluate(_DOM_JS, [_STRIP, list(_ROOTS)])
    except Exception:
        raw = page.inner_text("body")
    return tidy(raw)


def extract(page: Any, mode: ExtractMode) -> Extraction:
    """Shell: run the extractor the caller asked for."""
    match mode:
        case ExtractMode.DOM:
            return Extraction(text=dom_text(page), mode_used=ExtractMode.DOM)
        case ExtractMode.ARTICLE:
            return Extraction(text=article_text(page.content(), page.url),
                              mode_used=ExtractMode.ARTICLE)
        case _ as unreachable:
            assert_never(unreachable)
