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
