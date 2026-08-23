---
id: 044
title: Whether article's last job can be done structurally, and what to keep of trafilatura
labels: [wayfinder:grilling]
status: open
assignee:
blocked_by: []
---

## Question


[Whether dom alone is enough](025-whether-dom-alone-is-enough.md) is closed, and
its recommendation 2 is the load-bearing one: `article` stays. Its whole
justification is a single mechanism on a single page --

> The decoy root is fixable; a comment thread inside the content wrapper is not,
> because the comments *are* visible content and separating them from the post
> needs exactly the page-type judgement 011 established is not computable from
> the text. That is the thing `article` is for.

Everything else in 025 went `dom`'s way: its own heading says the premise
inverts, `dom` read fine on three of five pages, and the fourth failure
(americanthinker's decoy root) it called fixable and split off as
[028](028-the-root-heuristic-picks-a-decoy.md), now closed. By the end of that
ticket, **moonofalabama was the entire remaining case for keeping `article`.**

**That justification now has a hole in it.** Measured on the page itself -- see
[the structural signal
findings](../assets/029-structural-signal-findings.md) -- the separation 025
called uncomputable is computable, just not from the text. `#content` holds 106
children: 100 are comments carrying 90% of the characters, 81 of them sharing an
internal shape exactly, and the post is the one child whose shape occurs once.
Nothing in that reads a character count.

The inference in 025 has three steps: the separation needs a page-type
judgement; that judgement is not computable from the text (011); therefore
`article` must stay. Step two is right and this does not dispute
[011](011-listing-clears-the-yield-floor.md). What step three skips is a third
option -- *not from the text, but from the structure*.

**And 025 had already licensed that move, one paragraph earlier**, for the root
heuristic: "Choosing between candidate *roots* by size is a structural question
with a structural answer -- which element holds the document -- not a judgement
about what kind of page this is." It drew the distinction, used it to justify
028, and did not carry it to the comment case. The likely reason is where 025
stood: its table is `article` characters against `dom` characters per page, so it
was reasoning from two blobs of text, which is exactly the position 011 says
cannot answer this. It never looked at the DOM's shape.

**Why this is not [029](029-one-extractor-instead-of-two.md).** That ticket asks
whether one new extractor replaces both, and its answer is all-or-nothing: one
mode, or a port. This one asks the narrower question -- whether `article`'s *last
remaining job* can be done another way -- and it admits answers 029 rules out by
construction, including keeping trafilatura and taking only the part of it that
still earns its place. Neither blocks the other; they are competing shapes for
the same territory, and the structural measurement feeds both.

## What any replacement has to do

Inherited from [029](029-one-extractor-instead-of-two.md), which is closed in
favour of this ticket. These are 025's measurements, and they are the acceptance
criteria whichever of decision 3's shapes is chosen -- a strip pass added to
`dom` must not break the first list, and anything replacing `article` must
deliver the second.

**What `article` gets wrong today, and `dom` does not:**

- **Keep a listing.** Trafilatura discards a search page or a feed as
  boilerplate. That is why `dom` exists, and
  [011](011-listing-clears-the-yield-floor.md) established the choice between
  them is not computable from the text.
- **Keep the markers of withheld content.** chinadaily's piece has six pages and
  only `dom` carries the `_2`..`_6` links. After
  [015](015-only-the-first-screen-exists.md) and
  [016](016-the-result-says-what-it-missed.md) those markers are the caller's
  only signal that a page held something back.
- **Keep labels on what it keeps.** chinanews: `article` retains a related-news
  rail but loses its labels, emitting five bare timestamps under a heading.
- **See what is invisible.** gmw: `article` includes a hidden WeChat share
  overlay as body text; `dom` does not, because `checkVisibility()` filters it.
  Trafilatura reads static HTML and cannot see what is not displayed.
- **Keep links as [007](007-links-lost-in-dom-mode.md) settled them** --
  `[label](url)` inline, resolved against the document, never normalised.

**What `dom` gets wrong today, and `article` does not:**

- **Remove boilerplate at all.** moonofalabama: 128,718 characters around a
  9,569-character post. This is the case decision 1 is about, and the single
  reason 025 kept `article`.
- **Find the content without a selector list.** `_ROOTS` is six selectors, first
  match over 40 characters wins -- which on americanthinker was a sidebar promo
  card. [028](028-the-root-heuristic-picks-a-decoy.md) fixed the bug; the
  mechanism is still a selector list.
- **Emit tables.** `dom` emits none. Headings, list markers and fenced code
  landed in 09e1819 and are the floor, not the ceiling.

## To decide

1. **Whether the structural separation survives the case that would break it.**
   A repeated run beside a uniquely-shaped prose sibling is the proposed
   signature of "document with comments". A **listing with a lead paragraph**
   satisfies it too -- search results under an intro, a category page with a
   blurb, a forum index with a pinned notice -- and stripping those is precisely
   the failure `dom` exists to prevent. Untested, and decisive in the bad
   direction: if it misfires, 025's recommendation 2 stands as written and this
   ticket closes.

2. **Whether trafilatura is ported, kept, or reduced.** Three routes, and they
   are not degrees of one thing:
   - **Port it.** ~5,500 reachable lines plus justext plus an XPath-capable DOM
     library, as priced in [023](023-rewriting-into-csharp.md). Buys a known
     algorithm checkable against its own published evaluation. Twice the size of
     the program it serves.
   - **Keep it where it is.** If the tool stays Python, `article` costs nothing
     to keep -- it is a dependency, not code. The cost is only paid on a port,
     which makes this ticket's answer contingent on 023's and worth saying so
     out loud rather than discovering later.
   - **Reduce it to the part still doing work.** If the comment case goes
     structural, what is left of `article`'s value? 025 measured it *losing* on
     four axes -- it deletes chinadaily's `_2`..`_6` pagination links, loses
     chinanews's labels, cannot see gmw's hidden overlay, and discards listings
     outright. A fair reading is that trafilatura's remaining edge is
     boilerplate removal on a conventional article page, and that is the only
     thing worth carrying anywhere.

3. **What "best of both worlds" actually means mechanically.** At least three
   shapes, and picking one is most of the work:
   - **One extractor** (029's answer): a DOM-native walk that also strips.
   - **`dom` plus a structural strip step**: keep the walker exactly as it is,
     and add the run-detection as a separate pass over the same tree. Smallest
     change, and it leaves `article` untouched for callers who want it.
   - **Both, merged**: run trafilatura for its boilerplate judgement and the
     walker for visibility, links and markers, and reconcile. Most expensive,
     and it is two extractors again wearing one name -- likely the wrong answer,
     recorded so it is refused deliberately rather than forgotten.

4. **Whether `mode` survives either way.** 021 removed `auto` because the tool
   must not guess on the caller's behalf. A structural strip that fires by itself
   is a guess of the same family -- unless it is a *measurement* the caller is
   told about, in the shape [038](038-a-fetched-that-says-this-reads-like-a-wall.md)
   settled: report that a repeated run of N siblings was found and what it held,
   and let the caller decide. That framing may matter more than the algorithm.

5. **What the acceptance set is, given 025's cannot be re-run.** The five pages
   are recorded by site name and character count and **no URL for any of them
   exists** in the ticket or the assets. Whatever set this ticket uses, its URLs
   go in the asset.

6. **Where a strip pass would run, if there is one.** Inherited from 029, and
   reopened rather than answered. Its recorded answer -- C# over a
   `DOMSnapshot`, no JavaScript in the page -- was overturned when
   [030](030-the-walker-reads-a-snapshot.md) closed *no*: the walker stays
   JavaScript, because that string is the one part of `extract.py` a port
   inherits unchanged. The `DOMSnapshot.captureSnapshot` measurements in 029
   stand as measurements; the conclusion drawn from them does not. Since then
   [Fable](https://github.com/fable-compiler/Fable) has been measured as a third
   answer neither ticket had: F# compiled to JavaScript runs *in* the page, so
   the strip pass can be typed and unit-tested and still see the browser's real
   `innerText` and `checkVisibility()`. See [the port
   measurements](../assets/023-port-measurements-findings.md).

7. **Whether `dom`'s escape hatch survives.** Inherited from 029. If a strip
   pass or a single mode lands, a caller who disagrees with it currently has
   somewhere to go. Removing that is a separate loss from removing `article`,
   and it should be decided on purpose rather than fall out of the
   implementation.
