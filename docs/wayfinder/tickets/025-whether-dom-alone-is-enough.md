---
id: 025
title: Whether dom alone is enough
labels: [wayfinder:research]
status: open
assignee:
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
