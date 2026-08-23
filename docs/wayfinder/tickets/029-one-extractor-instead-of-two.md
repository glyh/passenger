---
id: 029
title: One extractor instead of two
labels: [wayfinder:grilling]
status: open
assignee:
blocked_by: [023]
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

### It may not be C# at all

The strong version of this dissolves half of 023's second phase. Trafilatura's
algorithm is lxml and XPath over static HTML, which is why porting it needs an
XPath-capable DOM library. A *DOM-native* algorithm has to run where the DOM
is -- as JavaScript evaluated in the page, exactly as `_DOM_JS` runs today,
with C# shipping and calling it. Then there is no lxml stand-in to find, no
5,500 lines to port, and the extractor is one artifact that both the Python
and C# sides could call during the alongside period 023 describes.

Whether that is right, or whether enough of the work is post-processing that
belongs in C#, is the architectural half of this ticket.

### To decide

1. **Whether one mode is actually reachable.** The moonofalabama test above.
   Everything else is conditional on it.
2. **Where the algorithm runs** -- in-page JavaScript, or C# over CDP.
3. **What the correctness bar is.** Trafilatura is checkable against its own
   published evaluation; that evaluation scores article extraction only, and
   scores nothing about keeping a listing. An extractor asked to do both has
   no published bar, and inventing one is not free.
4. **Whether any of trafilatura survives** -- its heuristics as a starting
   point, or a fresh algorithm that happens to serve the same purpose.
5. **Whether `dom`'s escape hatch survives anyway.** One mode is the goal, but
   a caller who disagrees with the extractor currently has somewhere to go.
   Removing that is a separate loss from removing `article`.
