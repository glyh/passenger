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

`auto` picks by measuring rather than guessing from the URL. Note that on every
page measured so far, `article` has won -- see README. `dom` is an escape
hatch, not a validated fix.
"""
import re
from typing import Any, assert_never

import trafilatura

from .models import Extraction, ExtractMode
from .text import count_words, unlinked

_STRIP = ("script, style, noscript, template, svg, nav, header, footer, aside, "
          "[role=navigation], [role=banner], [role=contentinfo], "
          "[aria-hidden=true], [hidden]")

_ROOTS = ("main", "[role=main]", "article", "#content", "#main", "body")

# Below this share of the page's visible words, the article extractor is
# assumed to have thrown away real content rather than boilerplate.
_ARTICLE_YIELD_FLOOR = 0.35
_MIN_COMPARABLE_WORDS = 40

_DOM_JS = r"""
([stripSel, roots]) => {
  const OPAQUE = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','SVG','IFRAME','CANVAS','SELECT']);
  const HEADING = {H1:'# ', H2:'## ', H3:'### ', H4:'#### ', H5:'##### ', H6:'###### '};
  const BLOCK = new Set(['ADDRESS','ARTICLE','ASIDE','BLOCKQUOTE','BR','BUTTON','DD','DETAILS',
    'DIALOG','DIV','DL','DT','FIELDSET','FIGCAPTION','FIGURE','FOOTER','FORM','H1','H2','H3',
    'H4','H5','H6','HEADER','HGROUP','HR','LI','MAIN','NAV','OL','OPTION','P','PRE','SECTION',
    'SUMMARY','TABLE','TBODY','TD','TFOOT','TH','THEAD','TR','UL']);

  let root = null;
  for (const sel of roots) {
    const el = document.querySelector(sel);
    if (el && (el.textContent || '').trim().length > 40) { root = el; break; }
  }
  root = root || document.body;

  // Walk the live document, not a detached clone: innerText on a clone is
  // textContent, which is why this used to return one unbroken run of text.
  const stripped = new Set(document.querySelectorAll(stripSel));
  const hrefs = new Map();
  for (const a of root.querySelectorAll('a[href]')) {
    hrefs.set(a.href, (hrefs.get(a.href) || 0) + 1);
  }

  const out = [];
  // A marker waits for the text it marks. `- ` written the moment an LI opens
  // lands alone on its line as soon as the item's first child is a block --
  // and on documentation most of them are, so the whole list came out as bare
  // dashes above their items. Deferring it also fixes the same case in a
  // heading whose text is wrapped in a div.
  let pending = '';
  const push = (s) => {
    if (!s) return;
    if (pending) { out.push(pending); pending = ''; }
    out.push(s);
  };
  const mark = (s) => { pending = s; };
  const nl = () => { if (out.length && !out[out.length - 1].endsWith('\n')) out.push('\n'); };
  // An anchor with no text still has a label often enough -- an icon link
  // carries it in aria-label, an image link in alt.
  const label = (el) => {
    const own = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
    if (own) return own;
    const img = el.querySelector('img[alt]');
    return (el.getAttribute('aria-label') || el.getAttribute('title')
            || (img && img.getAttribute('alt')) || '').replace(/\s+/g, ' ').trim();
  };

  const walk = (node, pre, depth) => {
    if (node.nodeType === 3) {
      push(pre ? node.nodeValue : node.nodeValue.replace(/\s+/g, ' '));
      return;
    }
    if (node.nodeType !== 1) return;
    if (OPAQUE.has(node.tagName) || stripped.has(node)) return;
    if (node.checkVisibility && !node.checkVisibility()) return;

    const raw = node.tagName === 'A' ? (node.getAttribute('href') || '') : '';
    // node.href resolves against the document, which is the point -- but it
    // also turns `#section` into a link back to this same page.
    if (raw && !raw.startsWith('#') && /^https?:/i.test(node.href)) {
      const text = label(node);
      // A URL with no label is cost without information -- unless nothing
      // else on the page points there, in which case dropping it would lose
      // the target outright. That keeps the one search result whose card is
      // a bare cover image, and drops the other nineteen cover anchors that
      // merely repeat their card's title link.
      if (text || (hrefs.get(node.href) || 0) < 2) {
        push('[' + text + '](' + node.href + ')');
      }
      return;
    }

    const block = BLOCK.has(node.tagName);
    if (block) nl();
    // Markdown structure. `dom` used to emit block boundaries and links and
    // nothing else, so a heading was a short line, a list was a run of short
    // lines, and a code sample was prose -- while trafilatura, asked for
    // markdown, emitted all of it. Ticket 009 found fenced code to be the one
    // axis on which an extractor visibly wins, which makes it the axis a
    // documentation page is lost on.
    const isPre = node.tagName === 'PRE';
    const list = node.tagName === 'UL' || node.tagName === 'OL';
    if (HEADING[node.tagName]) mark(HEADING[node.tagName]);
    else if (node.tagName === 'LI') mark('  '.repeat(Math.max(0, depth - 1)) + '- ');
    else if (isPre) push('```\n');
    for (const child of node.childNodes) walk(child, pre || isPre, depth + (list ? 1 : 0));
    if (isPre) { nl(); push('```'); }
    // An unflushed marker belongs to a block that turned out to hold nothing;
    // left standing it would label the next block's text instead.
    if (block) { pending = ''; nl(); }
  };

  walk(root, false, 0);
  return out.join('');
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
    """Shell: read visible text, links included, off the live page."""
    try:
        raw = page.evaluate(_DOM_JS, [_STRIP, list(_ROOTS)])
    except Exception:
        raw = page.inner_text("body")
    return tidy(raw)


def choose(article: str, dom: str) -> Extraction:
    """Pure: the `auto` decision, isolated so it can be tested without a page."""
    article_words = count_words(unlinked(article))
    dom_words = count_words(unlinked(dom))
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
