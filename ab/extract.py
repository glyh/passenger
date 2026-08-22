"""Turning a loaded page into text.

Two strategies, because pages come in two shapes:

  article  boilerplate removal (trafilatura). Right for documents -- news,
           docs, blogs, wikis. Wrong for app-like pages, where it strips the
           actual content as chrome and returns the nav bar.
  dom      visible text straight off the live DOM, minus obvious furniture.
           Noisier, but it's the only thing that sees a JS app's content.

`auto` picks between them by measuring, rather than guessing from the URL.
"""
import re

import trafilatura

# Structural furniture that is never the content, plus common cookie/consent
# containers that survive into innerText.
_STRIP = ("script, style, noscript, template, svg, nav, header, footer, aside, "
          "[role=navigation], [role=banner], [role=contentinfo], "
          "[aria-hidden=true], [hidden]")

# Preference order for the content root; body is the last resort.
_ROOTS = ("main", "[role=main]", "article", "#content", "#main", "body")

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
  // innerText on a detached clone loses layout-based visibility, so fall back
  // to the live node when the clone yields nothing useful.
  const txt = (root.innerText || '').trim();
  if (txt.length > 40) return txt;
  for (const sel of roots) {
    const live = document.querySelector(sel);
    if (live && (live.innerText || '').trim().length > 40) return live.innerText.trim();
  }
  return (document.body.innerText || '').trim();
}
"""


def article_text(html: str, url: str = "") -> str:
    out = trafilatura.extract(
        html, url=url or None, output_format="markdown",
        include_links=True, include_tables=True, favor_recall=True,
    )
    return (out or "").strip()


def dom_text(page) -> str:
    try:
        raw = page.evaluate(_DOM_JS, [_STRIP, list(_ROOTS)])
    except Exception:
        raw = page.inner_text("body")
    # innerText from an app is full of blank runs and repeated single glyphs.
    lines = [re.sub(r"[ \t ]+", " ", ln).strip() for ln in raw.splitlines()]
    kept, blanks = [], 0
    for ln in lines:
        if not ln:
            blanks += 1
            continue
        if blanks and kept:
            kept.append("")
        blanks = 0
        kept.append(ln)
    return "\n".join(kept).strip()


def extract(page, mode: str = "auto") -> tuple[str, str]:
    """Return (text, mode_used)."""
    if mode == "dom":
        return dom_text(page), "dom"
    article = article_text(page.content(), page.url)
    if mode == "article":
        return article, "article"

    # auto: trust the article extractor unless it recovered only a sliver of
    # what's actually on the page -- the signature of an app-shaped page whose
    # content got classified as boilerplate.
    dom = dom_text(page)
    a_words, d_words = len(article.split()), len(dom.split())
    if d_words >= 40 and a_words < 0.35 * d_words:
        return dom, "dom"
    return article, "article"
