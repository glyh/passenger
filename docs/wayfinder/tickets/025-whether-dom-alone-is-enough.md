---
id: 025
title: Whether dom alone is enough
labels: [wayfinder:research]
status: open
assignee: lyh (via Claude)
blocked_by: []
---

## Question

Whether `article` -- and with it trafilatura -- comes out, leaving `dom`
as the only extraction mode.

This surfaced from [Whether this moves to
C#](023-rewriting-into-csharp.md), where there is no .NET trafilatura, but
it is not a C# question and must not be decided there. Both extractors are
installed here and can be run against the same page; in C# there would be
nothing to compare against. It pays off on its own terms either way: if
`dom` is enough, `mode` has one value and `ExtractMode`, `choose`,
`_ARTICLE_YIELD_FLOOR`, `_MIN_COMPARABLE_WORDS` and `unlinked` all go with
it, which is the direction [How thin can this layer
get](020-how-thin-can-this-layer-get.md) set.

### First, fix what dom does not emit

`_DOM_JS` emits exactly two things: block boundaries, and inline
`[label](url)`. No headings, no list markers, no tables, no code fences --
`PRE` keeps its whitespace but gets no fence. `article_text` asks
trafilatura for `output_format="markdown"` with `include_tables=True`, so
it emits all four. On documentation that difference is not cosmetic:
[Whether defuddle belongs alongside
trafilatura](009-defuddle-as-a-mode.md) found fenced code blocks to be the
one axis on which an extractor visibly wins, and Python docs and
react.dev are both on the measured page list.

So `dom` gets `#`..`######` for `H1`-`H6`, `- ` for `LI`, and a fence
around `PRE` before anything is compared. The walker already carries a
`pre` flag; this is roughly ten lines of the JavaScript, and it is worth
having whether or not `article` survives.

### Then measure the thing that has never been measured

The README's `article` vs `dom` table is Wikipedia, Google Calendar,
Gmail and Google Maps. That was answering "does trafilatura break on
app-shaped pages" -- it does not -- and not "is `dom` acceptable on
documents". Nobody has run `dom` against the page shape `article` exists
for: a boilerplate-heavy news or blog page with no `main`, no
`[role=main]`, no `article`, no `#content` and no `#main`, where the root
heuristic falls through to `body` and returns the sidebar, the comment
thread and the related-articles rail alongside the piece.

Five such pages. Both modes. The verdict is a **read**, not a ratio:
[A listing clears the yield floor](011-listing-clears-the-yield-floor.md)
established that volume ratios are proxies for a property they cannot
see, and a yield floor is the machinery being deleted in
[Remove auto mode](021-remove-auto-mode.md) -- re-deriving one to decide
the extractor's fate would be the same mistake a level up.

### What follows

- **`dom` reads fine.** `article` and trafilatura come out. 021 collapses
  into this, `extract.py` roughly halves, and 023's extraction problem
  stops existing.
- **`dom` reads badly.** `article` stays, and 023 grows a second phase --
  porting trafilatura's extraction core to C#. That is live work, not a
  penalty (see 023); it is simply larger.

Either way this lands before any C# is written.

## Measured

From a second session, read-only: nothing under `ab/` was touched, the
improved walker was prototyped through `script`, and the numbers below come
from the project's own `extract` imported into the running server.

### Finding the shape took most of the effort

Body-fallthrough is rarer than the ticket assumes. Every modern Western news
and blog page probed matched `main` -- nypost, wnd, itmedia, lwn,
joelonsoftware, codinghorror. The shape lives in legacy Chinese portals.
163.com refused the connection twice, so the fifth slot is a comment-heavy
blog rather than a fifth news page.

| Page | Root picked | `article` | `dom` | ratio |
|---|---|---|---|---|
| chinadaily (en) | `body` | 1,639 | 5,521 | 3.4x |
| chinanews (zh) | `body` | 2,116 | 4,595 | 2.2x |
| gmw (zh) | `body` | 3,302 | 5,397 | 1.6x |
| americanthinker (en) | `article` | 5,769 | **273** | 0.05x |
| moonofalabama (en) | `#content` | 9,569 | **128,718** | 13.5x |

### The premise inverts

**Where this ticket predicted failure, `dom` read fine.** On all three
body-fallthrough pages the piece comes out whole and contiguous, wrapped in
furniture that is obviously furniture: a strip of channel links above, a
related rail and a footer below. 1.6x to 3.4x is a cost, not a corruption.
Read as prose, none of the three would mislead a caller.

**Both catastrophes are pages where the root heuristic *matched something*,**
and neither is an extraction-quality failure:

- **americanthinker** has 30 `<article>` elements, every one a sidebar teaser
  card of 79-196 chars. `querySelector('article')` takes the first, the
  40-char guard waves its 164 chars through, and `dom` returns 273 characters
  -- the promo card for the very article that was asked for. The 5,769-char
  piece is never reached.
- **moonofalabama** wraps the post *and* about a hundred comments in
  `#content`, so `dom` returns 128,718 chars around a 9,569-char post. This is
  the predicted sidebar-and-comment-thread failure, arriving through a matched
  selector rather than through `body`.

### `article` is not clean either

Recorded because it weakens the reading that `article` is the safe half:

- **chinadaily**: `article` drops the byline, the photo credit, and the
  pagination. The piece has **six pages**, and only `dom` carries the `_2`..`_6`
  links. That is a [015](015-only-the-first-screen-exists.md)-style
  withheld-content marker that the article extractor deletes outright.
- **chinanews**: `article` keeps a related-news rail but loses its labels,
  emitting five bare timestamps under a heading.
- **gmw**: `article` includes the hidden WeChat share overlay as body text.
  `dom` does not -- `checkVisibility()` filters it. Trafilatura reads static
  HTML and cannot see what is invisible.

### The markup work, against the walker now in the tree

| | `article` | `dom` before | `dom` now |
|---|---|---|---|
| docs.python.org/asyncio-task | 55,443 ch / 8 code blocks | 49,691 / 0 | 51,425 / **34** |
| react.dev/state | 19,583 / 1 | 11,337 / 0 | 11,998 / 10 |

It lands the axis [009](009-defuddle-as-a-mode.md) named: 34 fenced blocks
against trafilatura's 8. Two things still open, measured against the working
tree rather than inferred:

- **`LI` orphans its marker when the item's child is a block.** `push('- ')`
  is followed by the child `P`'s `nl()`, so the dash lands alone on its line:
  docs.python.org gets **8 orphan dashes and 0 usable bullets**, react.dev
  gets 23 clean ones because its items are inline. The marker has to be
  deferred until the first text actually lands.
- **react.dev's sandpack editors defeat both modes.** The live code panels are
  divs, not `PRE`, so neither extractor fences them.

The `tidy` fence exemption in the same change is load-bearing and was reached
independently here: without it `dom` flattens `    print(x)` to `print(x)`,
which on Python is not cosmetic.

### One interaction with 021

On americanthinker today, `auto` picks `article`: `dom` yields 11 words,
under `_MIN_COMPARABLE_WORDS` (40), so `choose` never considers it. That
floor is currently the only thing standing between a caller and a broken
root. [011](011-listing-clears-the-yield-floor.md) still holds and
[021](021-remove-auto-mode.md) is still right, but the root fix has to land
before or with it -- otherwise the decoy failure stops being conditional and
becomes simply what `dom` mode does on that page.

## Recommendation

**Neither fork as written.** Not "`dom` reads fine, `article` comes out": two
of five pages say no. Not "`dom` reads badly, port trafilatura": where `dom`
was supposed to read badly it read fine. The verdict splits by *why* each
failure happens, and the two halves have different answers.

1. **Split the root heuristic out as its own ticket, and rank it above 021.**
   Filed as [The root heuristic picks a
   decoy](028-the-root-heuristic-picks-a-decoy.md), which now blocks 021.
   `_ROOTS` is a six-entry tuple taking the first match over 40 chars, and on
   americanthinker that is a live bug today, in `dom` mode, independent of
   this ticket, of 021 and of 023. Candidate rule: among *all* matching
   candidates take the one with the most text, and distrust `article`
   entirely when the document holds many of them.

   Note this is not the mistake [011](011-listing-clears-the-yield-floor.md)
   warns about. Choosing between candidate *roots* by size is a structural
   question with a structural answer -- which element holds the document --
   not a judgement about what kind of page this is. The floor 011 deleted was
   asked to decide the latter from the former.

2. **`article` stays, and 021 does not collapse into this.** The reason is
   moonofalabama, not americanthinker. The decoy root is fixable; a comment
   thread inside the content wrapper is not, because the comments *are*
   visible content and separating them from the post needs exactly the
   page-type judgement 011 established is not computable from the text. That
   is the thing `article` is for, and it is why `dom` alone is not enough.

3. **Keep the markup work regardless.** It wins on code blocks 34 to 8, it is
   already written, and every future in which `dom` matters needs it.

4. **021 should default to `article`,** and must not land before the root fix.
   With the root broken, `article` is the safer of the two defaults by a wide
   margin, and the 40-word floor that currently hides the breakage goes away
   with `auto`.

5. **023 grows its second phase.** The extraction question does not go away in
   C#: something has to do what trafilatura does. That is now decided here
   rather than left open there.

Re-point this ticket at the question the measurement actually raises:
whether a repaired root heuristic changes the answer for the pages where
`dom` failed structurally. On present evidence it changes one of the two, and
the other is the answer.
