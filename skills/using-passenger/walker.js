// The DOM walker: visible text off the live document, as markdown.
//
// This file is one JavaScript expression -- an arrow function -- because
// `page.evaluate` calls it with the argument array `extract.py` passes.
// Nothing else may be at the top level. `_STRIP` and `_ROOTS` stay on the
// Python side and arrive as parameters; they are the two things a reader
// looks for first, and a test that wants to pin the root heuristic varies
// them without touching this file.
//
// It stays JavaScript deliberately. Ticket 030 weighed rewriting it in Python
// over a `DOMSnapshot` and refused: this is the one part of `extract.py` that
// a C# port inherits unchanged, and the walker's semantics *are* `innerText`,
// `checkVisibility()` and layout -- which is also why every test of it runs in
// a real browser rather than jsdom.
//
// There is no seam here for tests to reach into. `tests/test_walker.py` enters
// through `dom_text`, which is the only call site that exists in production.
(args) => {
  const DEFAULT_STRIP =
    'script, style, noscript, template, svg, nav, header, footer, aside, ' +
    '[role=navigation], [role=banner], [role=contentinfo], ' +
    '[aria-hidden=true], [hidden]';

  // Candidate containers, most specific first. `body` is not among them: it
  // matches on every page and holds everything, so as a candidate it could never
  // lose. It is the fallback, and the walk names it as one.
  const DEFAULT_ROOTS = ['main', '[role=main]', 'article', '#content', '#main'];
  // Defaults live here now. They used to be `_STRIP` and `_ROOTS` in
  // extract.py, passed in on every call, on the reasoning that they are the
  // two things a reader looks for first and a test pinning the root heuristic
  // should vary them without touching this file. Both still hold -- the
  // argument is still accepted, and `tests/test_walker.py` still varies it --
  // but there is no Python side to hold the defaults any more, and a recipe an
  // agent pastes should be callable with no arguments at all.
  // Destructured inside rather than in the parameter list, and guarded for
  // null rather than undefined: `page.evaluate(source)` with no argument sends
  // *null*, so a default parameter never fires and `[a, b] = null` throws.
  const [stripSel = DEFAULT_STRIP, roots = DEFAULT_ROOTS] = args || [];
  const OPAQUE = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','SVG','IFRAME','CANVAS','SELECT']);
  const HEADING = {H1:'# ', H2:'## ', H3:'### ', H4:'#### ', H5:'##### ', H6:'###### '};
  const BLOCK = new Set(['ADDRESS','ARTICLE','ASIDE','BLOCKQUOTE','BR','BUTTON','DD','DETAILS',
    'DIALOG','DIV','DL','DT','FIELDSET','FIGCAPTION','FIGURE','FOOTER','FORM','H1','H2','H3',
    'H4','H5','H6','HEADER','HGROUP','HR','LI','MAIN','NAV','OL','OPTION','P','PRE','SECTION',
    'SUMMARY','TABLE','TBODY','TD','TFOOT','TH','THEAD','TR','UL']);

  // What the walk emits into, and the marker that is waiting for its text.
  const out = [];
  let pending = '';

  // --- choosing where to start -------------------------------------------

  // A selector that matches many elements has not found the document's
  // container; it has found a collection of them, and the first one is a
  // card. americanthinker carries 30 <article> promo teasers of 79-203
  // characters, so `querySelector('article')` returned the card advertising
  // the very piece that was asked for -- 273 characters, while the
  // 5,769-character article was never reached (ticket 028).
  //
  // Counting matches is not the yield ratio ticket 011 deleted. That one
  // judged a page's *type* by volume, which volume cannot tell you. This is a
  // structural question -- which element is the document -- with a structural
  // answer, and nothing here is measured against anything else.
  function chooseRoot() {
    for (const sel of roots) {
      const els = document.querySelectorAll(sel);
      if (els.length !== 1) continue;
      // Not a quality bar. A selector can match a shell the page never filled,
      // and the content then lives somewhere else entirely.
      if ((els[0].textContent || '').trim().length > 40) return els[0];
    }
    return document.body;
  }

  // How many anchors point at each URL, which is what decides whether an
  // unlabelled one is worth its cost. Resolved hrefs, so two spellings of one
  // target count together.
  function countHrefs(el) {
    const seen = new Map();
    for (const a of el.querySelectorAll('a[href]')) {
      seen.set(a.href, (seen.get(a.href) || 0) + 1);
    }
    return seen;
  }

  // --- the emitter --------------------------------------------------------

  // A marker waits for the text it marks. `- ` written the moment an LI opens
  // lands alone on its line as soon as the item's first child is a block --
  // and on documentation most of them are, so the whole list came out as bare
  // dashes above their items. Deferring it also fixes the same case in a
  // heading whose text is wrapped in a div.
  function push(s) {
    if (!s) return;
    if (pending) { out.push(pending); pending = ''; }
    out.push(s);
  }

  function mark(s) { pending = s; }

  function nl() {
    if (out.length && !out[out.length - 1].endsWith('\n')) out.push('\n');
  }

  // An anchor with no text still has a label often enough -- an icon link
  // carries it in aria-label, an image link in alt.
  function label(el) {
    const own = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
    if (own) return own;
    const img = el.querySelector('img[alt]');
    return (el.getAttribute('aria-label') || el.getAttribute('title')
            || (img && img.getAttribute('alt')) || '').replace(/\s+/g, ' ').trim();
  }

  // --- the walk -----------------------------------------------------------

  function walk(node, pre, depth) {
    if (node.nodeType === 3) {
      push(pre ? node.nodeValue : node.nodeValue.replace(/\s+/g, ' '));
      return;
    }
    if (node.nodeType !== 1) return;
    if (OPAQUE.has(node.tagName) || stripped.has(node)) return;
    // `visibilityProperty` is opted into; the other two options are not, and
    // that asymmetry is measured rather than cautious (ticket 035).
    //
    // With no arguments at all this reports on `display:none` and nothing
    // else, which is not what the call looks like it does. Adding
    // `visibilityProperty` drops hidden furniture and cost nothing on nine
    // pages. Adding `opacityProperty` is the one that must not be taken:
    // scroll-triggered reveal holds below-the-fold content at `opacity: 0`
    // until the reader arrives, and this tool never scrolls, so apple.com
    // went from 13,081 characters to 3,761 -- real body text, not chrome, for
    // a gain of three lines of dialog furniture elsewhere.
    // `contentVisibilityAuto` changed nothing anywhere it was tried, and the
    // page picked to exercise it returned nothing at all, so it is untested
    // rather than safe.
    if (node.checkVisibility && !node.checkVisibility({visibilityProperty: true})) return;

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
  }

  // --- tidying ------------------------------------------------------------

  // Collapse the blank runs and stray whitespace the walk leaves behind. This
  // was `tidy()` in extract.py and moved here when `fetch` was retired and the
  // walker became the whole contract: there is no Python side left to run it,
  // and the raw walk now exists nowhere outside this function.
  //
  // A fenced block passes through verbatim, because the one thing whose
  // indentation *is* its meaning must not be collapsed line by line. On the
  // Python side that meant re-detecting the fence by matching lines equal to
  // ```; here `isPre` already knew, but the walk has finished by now, so the
  // marker is still what there is to go on.
  //
  // The character class is space, tab and U+00A0 deliberately: a non-breaking
  // space is what CJK portals pad cells with, and leaving it uncollapsed puts
  // a run of them through into the markdown.
  function tidy(raw) {
    const kept = [];
    let pendingBlank = false, inFence = false;
    // Python's splitlines() breaks on more than \n -- \r, \v, \f and the
    // unicode separators -- and a `pre` can carry any of them out of the page.
    for (const line of raw.split(/\r\n|[\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029]/)) {
      if (line.trim() === '```') {
        if (!inFence && pendingBlank && kept.length) kept.push('');
        pendingBlank = false;
        inFence = !inFence;
        kept.push('```');
        continue;
      }
      if (inFence) { kept.push(line.replace(/\s+$/, '')); continue; }
      const text = line.replace(/[ \t\u00a0]+/g, ' ').trim();
      if (!text) { pendingBlank = true; continue; }
      if (pendingBlank && kept.length) kept.push('');
      pendingBlank = false;
      kept.push(text);
    }
    return kept.join('\n').trim();
  }

  // --- and go -------------------------------------------------------------

  // Walk the live document, not a detached clone: innerText on a clone is
  // textContent, which is why this used to return one unbroken run of text.
  const root = chooseRoot();
  const stripped = new Set(document.querySelectorAll(stripSel));
  const hrefs = countHrefs(root);

  walk(root, false, 0);
  return tidy(out.join(''));
}
