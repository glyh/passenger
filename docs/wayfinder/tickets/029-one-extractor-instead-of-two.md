---
id: 029
title: One extractor instead of two
labels: [wayfinder:grilling]
status: open
assignee:
blocked_by: [023, 030]
---

## Question

Trafilatura is reimplemented rather than ported, and the reimplementation is
strong enough that `mode` has one value: it covers what `article` misses *and*
what `dom` misses, and both modes collapse into it. Output stays markdown --
[027](027-asciidoc-rather-than-markdown.md) closed that.

This supersedes the shape [023](023-rewriting-into-csharp.md) currently
carries. Its second phase is written as a port: about 5,500 reachable lines of
trafilatura, plus justext, plus an XPath-capable DOM library standing in for
lxml. A reimplementation is a different trade -- fewer lines, and no published
evaluation to check them against.

It does not overturn [025](025-whether-dom-alone-is-enough.md). That ticket
measured the two extractors that exist and found each one necessary; this asks
whether a third makes both unnecessary. 025's five pages are the acceptance
set either way.

### What it must do that `article` does not

All five from 025's measurements:

- **Keep a listing.** Trafilatura discards a search page or a feed as
  boilerplate -- that is why `dom` exists at all, and
  [011](011-listing-clears-the-yield-floor.md) established the choice between
  them is not computable from the text.
- **Keep the markers of withheld content.** chinadaily's piece has six pages
  and only `dom` carries the `_2`..`_6` links; `article` deletes them. After
  [015](015-only-the-first-screen-exists.md) and
  [016](016-the-result-says-what-it-missed.md) those markers are the caller's
  only signal that a page held something back, so an extractor that strips
  them is destroying the thing the agent is told to look for.
- **Keep labels on what it keeps.** chinanews: `article` retains a related-news
  rail but loses its labels, emitting five bare timestamps under a heading.
- **See what is invisible.** gmw: `article` includes a hidden WeChat share
  overlay as body text. `dom` does not, because `checkVisibility()` filters it.
  Trafilatura reads static HTML and cannot see what is not displayed.
- **Keep links as [007](007-links-lost-in-dom-mode.md) settled them** --
  `[label](url)` inline, resolved against the document, never normalised.

### What it must do that `dom` does not

- **Remove boilerplate at all.** moonofalabama returns 128,718 characters
  around a 9,569-character post, because `#content` legitimately wraps the post
  *and* a hundred comments. This is the single reason 025 kept `article`, and
  it is the hard case.
- **Find the content without a selector list.** `_ROOTS` is six selectors and
  the first match over 40 characters wins, which on americanthinker is a
  sidebar promo card --
  [028](028-the-root-heuristic-picks-a-decoy.md). A real extractor does not
  pick its root this way. 028 still lands in Python regardless; this replaces
  the mechanism rather than the fix.
- **Emit tables.** `dom` emits none. Headings, list markers and fenced code
  landed in 09e1819 and are the floor, not the ceiling.

### The claim that makes one mode possible

011 concluded that no signal computed from *the text* can tell which extractor
is right, because that depends on the page's type. Every argument since --
including 025's, and the yield floor 021 is deleting -- has inherited that.

**A DOM-native extractor is not reading text.** It has computed style,
geometry, visibility, ARIA roles, and repeated sibling structure. 025 already
recorded one case where that beat trafilatura outright: `checkVisibility()`
caught the hidden overlay static HTML could not. moonofalabama's comment
thread is structurally a run of near-identical siblings each carrying an
author, a timestamp and a permalink -- which is a structural signature, not a
volume ratio, and 011's objection does not obviously reach it.

If that reading holds, one mode is reachable. If it does not, this is a port
after all and `article` stays. **Establish it before writing any C#** -- the
test is Python, against 025's five pages, and moonofalabama is the one that
decides.

### Where it runs: measured, and it is C#

The first draft of this ticket argued a DOM-native algorithm has to run *in*
the page as JavaScript, the way `_DOM_JS` does. That is wrong, and one CDP
call disproves it.

`DOMSnapshot.captureSnapshot` returns the flattened tree -- `parentIndex`,
`nodeName`, `nodeType`, `nodeValue`, `attributes`, `isClickable` -- and, for
every node that generated a box, `bounds`, `clientRects`, `offsetRects`,
`scrollRects`, `paintOrders`, `stackingContexts`, and whichever computed
styles the caller names. Strings are interned in a table. Measured on the
live session:

| | docs.python.org | moonofalabama |
|---|---|---|
| HTML | 279,633 B | 81,385 B |
| snapshot JSON | 1,938,881 B | 380,414 B |
| capture | 566 ms | 143 ms |
| nodes / laid out | 13,473 / 11,535 | 2,324 / 2,202 |

Every live-DOM fact this walker goes into the page for is in there. So the
extractor is ordinary C# over a JSON structure, in real files with real types,
and **there is no JavaScript to structure because there is no JavaScript.**

**Not Blazor.** Running C# in the page is possible -- .NET compiles to
WebAssembly -- and is the wrong trade twice over. DOM access from WASM goes
through JS interop per call, so walking 13,473 nodes is 13,473 marshalled
round trips, which is why Blazor's own renderer batches. And injecting a
multi-megabyte .NET runtime into the page contradicts the one property the
whole tool rests on: a session sites cannot distinguish from an ordinary
browser. Bring the DOM to C#, not C# to the DOM.

**Split out, and takeable now.** Everything in this section is available in
Python today and needs no C# at all, so it left as [The walker reads a
snapshot, not the page](030-the-walker-reads-a-snapshot.md). This ticket
keeps only the question C# does not answer -- whether one mode is
reachable -- and waits on 030 for the substrate and the fixtures that
make the moonofalabama experiment cheap.

**The testability is the prize.** `_DOM_JS` cannot be unit tested: it is a
string of JavaScript that needs a browser, which is why
[001](001-testing-the-shells.md)'s rule has never reached it and why the
markup work in [025](025-whether-dom-alone-is-enough.md) had to be verified
against live pages instead. A snapshot is a file. Fixtures are saved
snapshots, the extractor is a pure function from snapshot to markdown, and the
functional-core/imperative-shell line lands where it belongs -- capture is the
shell, extraction is the core.

**What is not yet verified**, and is the first task rather than an assumption:
that every fact the current walker uses survives the trip. Resolved `href`
(the snapshot carries the raw attribute, so resolution against the document
URL moves into the extractor), `aria-label`, `title` and `img[alt]` (plain
attributes), and `checkVisibility()` -- derivable from layout presence plus
`display`/`visibility`/`opacity`, but *derivable* is not *identical*, and gmw's
hidden WeChat overlay is the case that must keep being filtered.

A cost to weigh: the snapshot is five to seven times the HTML as JSON. It
never leaves the process and is not the payload, so this is memory and parse
time, not the caller's context budget.

### To decide

1. **Whether one mode is actually reachable.** The moonofalabama test above.
   Everything else is conditional on it.
2. ~~**Where the algorithm runs.**~~ Answered above: C# over a
   `DOMSnapshot`, with no JavaScript in the page. What remains is
   verifying the snapshot carries every fact the current walker uses.
3. **What the correctness bar is.** Trafilatura is checkable against its own
   published evaluation; that evaluation scores article extraction only, and
   scores nothing about keeping a listing. An extractor asked to do both has
   no published bar, and inventing one is not free.
4. **Whether any of trafilatura survives** -- its heuristics as a starting
   point, or a fresh algorithm that happens to serve the same purpose.
5. **Whether `dom`'s escape hatch survives anyway.** One mode is the goal, but
   a caller who disagrees with the extractor currently has somewhere to go.
   Removing that is a separate loss from removing `article`.
