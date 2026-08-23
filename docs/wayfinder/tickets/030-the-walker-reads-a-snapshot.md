---
id: 030
title: The walker reads a snapshot, not the page
labels: [wayfinder:task]
status: open
assignee:
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
