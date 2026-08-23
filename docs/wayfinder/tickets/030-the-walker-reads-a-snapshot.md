---
id: 030
title: The walker reads a snapshot, not the page
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: [028]
---

## Question

`_DOM_JS` becomes a pure Python function over a `DOMSnapshot`, and the string
of JavaScript goes away.

Split out of [One extractor instead of
two](029-one-extractor-instead-of-two.md), which measured the mechanism and
found it needs no C# and no rewrite to be worth doing. This is the same change
in the language the tool is written in today, and it pays for itself here:

- **The walker becomes testable.** It cannot be unit tested now -- it is a
  string of JavaScript needing a real browser, which is why
  [001](001-testing-the-shells.md)'s rule has never reached it and why the
  markup work in [025](025-whether-dom-alone-is-enough.md) had to be verified
  against live pages by hand. A snapshot is a file: fixtures are saved
  snapshots and the extractor is a pure function.
- **It is the design 029 needs, proven early.** If the snapshot carries
  everything, the C# port inherits a design already working. If it does not,
  that is learned here, in Python, before anything is committed to.
- **The functional-core line lands where it belongs.** Capture is the shell;
  the walk is the core.

### What the snapshot gives

One CDP call, measured on the live session in 029: the flattened tree with
`parentIndex`, `nodeName`, `nodeType`, `nodeValue`, `attributes` and
`isClickable`, plus per laid-out node `bounds`, `clientRects`, `offsetRects`,
`scrollRects`, `paintOrders`, `stackingContexts` and whichever computed styles
are named. 1.9 MB of JSON in 566 ms on a large docs page; 380 KB in 143 ms on
moonofalabama. It never leaves the process and is not the payload, so its size
is memory and parse time, not the caller's context budget.

### The one thing that could sink it, and does not

**A snapshot has no `querySelector`.** Both selector lists the walker relies on
are CSS, and there is no CSS engine on the other side. Checked, and they
survive: every entry in `_STRIP` and `_ROOTS` is a bare tag name or a single
attribute predicate --

    _STRIP  script, style, noscript, template, svg, nav, header, footer,
            aside, [role=navigation], [role=banner], [role=contentinfo],
            [aria-hidden=true], [hidden]
    _ROOTS  main, [role=main], article, #content, #main, body

-- and the snapshot carries `nodeName` and `attributes` for every node, so all
of them match directly. No selector engine is needed, and none should be
added: the day one of these grows a descendant combinator is the day this
decision is revisited deliberately rather than by accident.

### What must survive the trip, verified rather than assumed

Each of these is a behaviour some earlier ticket paid for, and the rewrite is
wrong if any regresses:

- **`checkVisibility()`.** Layout presence catches `display:none`; elements
  with `visibility:hidden`, `opacity:0` or `content-visibility` still generate
  boxes, so the requested computed styles have to cover them. Derivable is not
  identical. The case that must keep being filtered is gmw's hidden WeChat
  share overlay, which [025](025-whether-dom-alone-is-enough.md) recorded
  trafilatura swallowing and `dom` correctly dropping.
- **Links exactly as [007](007-links-lost-in-dom-mode.md) settled them.**
  The snapshot carries the raw `href` attribute, so resolution against the
  document URL moves into Python -- and must stay a resolution and not become
  a normalisation, because a signed query string *is* the URL. The
  "drop a bare-URL anchor unless nothing else points there" rule needs the
  same href histogram, which is now a pass over the node table.
- **Labels from `aria-label`, `title` and `img[alt]`** -- plain attributes.
- **`PRE` whitespace**, and the fences, headings and list markers added in
  09e1819, including the deferred-marker rule.
- **The root choice**, whatever [028](028-the-root-heuristic-picks-a-decoy.md)
  settles it to. This is blocked on 028 rather than the reverse: that is a live
  bug in `dom` mode today and must not wait on a refactor. The rule gets
  written twice, which is a few lines, and the second time it gets a real test.

### Tested

This is the ticket where the walker finally earns tests under 001's rule, and
every one of them names a failure that already happened: the detached-clone
bug that cost `dom` its block boundaries (007), links pointing nowhere (007),
the orphaned list marker (025), indentation stripped inside a fence (025), and
the decoy root (028). Fixtures are captured snapshots checked into the repo,
so no test starts the real stack.

### Open

1. **Whether `article` mode also moves.** Trafilatura takes HTML and this
   changes nothing for it, so the two extractors would read the page through
   two different mechanisms. Probably fine and worth stating rather than
   drifting into.
2. **Iframes.** `captureSnapshot` returns every document, not just the top
   one; the walker treats `IFRAME` as opaque today. Keeping that is the safe
   default and should be a decision, not an oversight.
3. **Whether the capture is one call or two.** Attributes and computed styles
   come from the same call, but the page must be settled first, and `fetch`
   already has a `settle_ms`. No new waiting should appear.

## Answer

No. The walker stays a string of JavaScript evaluated in the page, and the
work this ticket wanted is carried by [A broken walker passes its own
tests](034-broken-walker-passes-its-tests.md) instead.

Two things overturned it, and neither was visible when it was written.

**The JavaScript is the one part of `extract.py` that survives the C# port
unchanged.** [023](023-rewriting-into-csharp.md) and
[029](029-one-extractor-instead-of-two.md) will still drive a browser, and
`Runtime.evaluate` is the same call from C# as from Python. This ticket argued
the snapshot rewrite would hand the port "a design already working"; what it
would actually hand it is a Python walker that must then be written a third
time. The string of JavaScript is host-language-agnostic, which is the
property the port most wants and the one this ticket proposed to spend.

**The testability that justified it was already there, unused.** The premise
above -- "it cannot be unit tested now" -- was false when it was written.
[028](028-the-root-heuristic-picks-a-decoy.md) had already built the harness:
`tests/test_walker.py` starts a headless chromium, hands it `set_content`
fixtures and calls `dom_text`, and `flake.nix` pins a `pkgs.chromium` in
`checks.default` so it runs rather than skips. The cost that this rewrite was
going to pay for had been paid. What was missing was tests, and a rewrite is
an expensive way to write them.

There is also a reason not to want the pure-Python version even if it were
free. The walker's semantics *are* `innerText`, `checkVisibility()` and
layout. Any harness that does not use a real browser -- jsdom, or a snapshot
replayed through hand-written matching -- stubs exactly those three, and
tests the parts that never break while missing the parts that do. The
real-browser fixture harness is not a compromise forced by the JavaScript; it
is the only correct harness, which makes the JavaScript's location a
non-issue.

### The selector question, explored and then moot

Before the premise was revoked, the "no selector engine is needed" line above
was reopened deliberately, which is what it asked for. Three ways to preserve
`querySelector` and XPath over a snapshot were weighed:

1. **Rebuild the snapshot as an lxml tree.** XPath is free -- lxml is already
   present transitively via trafilatura -- but CSS needs `cssselect`, which
   translates a subset of CSS into XPath, so answers would diverge from the
   page's own in ways nobody predicts in advance.
2. **Resolve selectors in the capture shell over CDP**, in Blink's own engine,
   handing the core a set of `backendNodeId`s -- `DOM.querySelectorAll`, or
   `DOM.performSearch` which takes plain text, CSS *or* XPath.
   `captureSnapshot` carries `backendNodeId` on every node, so the bridge
   exists.
3. **Match over the flattened node table**, which is what this ticket assumed.

2 was chosen and then revoked, before any code was written. What broke it was
scope rather than mechanism: two of the walker's selector sites are per-element
subtree queries, and `el.querySelector('img[alt]')` runs *once per anchor*. On
a listing with four hundred anchors that is four hundred roundtrips, so option
2 could never have been the uniform rule it was recorded as.

### Two corrections to the question above, kept because a revisit would trip on them again

- **The walker queries in four places, not two.** Beyond `_STRIP` and
  `_ROOTS`, `extract.py:84` runs `root.querySelectorAll('a[href]')` for
  [007](007-links-lost-in-dom-mode.md)'s href histogram, and `extract.py:107`
  runs `el.querySelector('img[alt]')` inside `label()`. Both are scoped
  subtree queries and neither appears in either constant.
- **`_ROOTS` does not contain `body`.** The list quoted above ends in it; the
  code does not, and the comment at `extract.py:45` says why -- `body` matches
  on every page and holds everything, so as a candidate it could never lose.
  It is the fallback outside the loop.
- **Labels do not come primarily from attributes.** The list above records
  `aria-label`, `title` and `img[alt]` as "plain attributes", but
  `extract.py:105` reads `innerText || textContent` *first* and reaches the
  attributes only when that is empty. The primary path went unlisted, which is
  the sort of omission a rewrite discovers by regressing.

### The three open questions

1. **Whether `article` mode also moves.** Moot; nothing moves. Trafilatura
   still takes `page.content()` and the two extractors still read the page two
   ways, which was true before this ticket and remains acceptable.
2. **Iframes.** Moot as asked, but the underlying decision stands and is now
   explicit: `IFRAME` is opaque, deliberately, and a page whose content lives
   in one is reached with `script`.
3. **Whether the capture is one call or two.** Moot; there is no capture.
