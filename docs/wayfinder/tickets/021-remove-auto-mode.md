---
id: 021
title: Remove auto mode
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: [028]
---

## Question

Blocked on [Whether dom alone is enough](025-whether-dom-alone-is-enough.md),
which can delete this ticket's central question rather than answer it. If
`dom` reads acceptably on document-shaped pages then `article` comes out
whole, and there is no default to choose between -- `mode` has one value.
Deciding that default first is picking between two options one of which may
not survive the week. Question 5 is the exception: `PageProbe.word_count` is
dead today and independent of everything else here.

[A listing clears the yield floor on a
footer](011-listing-clears-the-yield-floor.md) concluded that no signal
computed from the two extractions can choose between them, because which
one is right depends on the page's *type* and that is not in the text.
This is the removal.

Out: `ExtractMode.AUTO`, `choose`, `_ARTICLE_YIELD_FLOOR`,
`_MIN_COMPARABLE_WORDS`, and `tests/test_extract.py`, which tests nothing
else. `extract` collapses to a two-armed match.

To decide:

1. **What replaces the default.** `auto` is the default on both doors
   today, so this is an output-contract change however it goes.
   - *Required, no default* is the honest reading of 011: the caller
     knows the page type, so make it say. It also breaks every call that
     omits the argument, and leaves a caller who genuinely does not know
     with nothing to fall back on.
   - *Default `article`* keeps documents working with no argument, which
     is the majority of the web, and fails on listings exactly as it does
     now -- except that it would fail *honestly*, since nothing would be
     claiming to have chosen.
   - *Default `dom`* never silently drops a listing's content, and makes
     every article noisier.
   The middle one is not obviously right. Note that "fails the same way
   but without pretending to have decided" is a real improvement even
   with no behaviour change, and worth not undervaluing.
2. **What the caller is told instead.** If the tool stops choosing, the
   description has to carry what it knew -- listings and profiles want
   `dom`, documents want `article` -- in about two lines. That is the
   same trade made when [the fetch description gained its first-screen
   caveat](016-the-result-says-what-it-missed.md): prose that changes
   what the caller does on every call earns its room.
3. **What is left of the word counting.** This is the interesting half.
   `count_words` had two consumers: `classify`, removed in [The extract
   mode decides whether a page counts as
   blocked](005-mode-decides-blocked.md), and `choose`, removed here.
   After this, nothing *decides* anything with a word count -- it
   survives only as `Fetched.word_count`, a number reported for the
   caller's information.

   That makes PyICU, the project's one native dependency and the reason
   the Python side moved to nix at all, load-bearing for a display field.
   Measured on the `choose` fixtures, character counts agreed with ICU on
   every case where `split()` did not, because a ratio needs a consistent
   unit rather than a correct one -- but with no ratio left, even that
   argument is gone. So: does `word_count` stay a word count, become a
   character count, or stop being reported? `unlinked` exists only for
   measuring and follows whatever this decides.

   **Also blocked on [The root heuristic picks a
   decoy](028-the-root-heuristic-picks-a-decoy.md).** `auto` is what currently
   hides that bug: it measures `dom` at 11 words on americanthinker, under
   `_MIN_COMPARABLE_WORDS`, and returns `article` instead. Remove `auto` with
   the root still broken and the failure stops being conditional.

   **Decided: the dependency comes out.** Carried as [Drop
   ICU](022-drop-icu.md), which this blocks, so that the auto removal
   lands without dragging `pyproject.toml`, the flake and the overlay in
   with it. What remains open there is what `word_count` becomes, not
   whether ICU stays.
4. Whether the CLI's `--dom` shorthand survives. It exists because
   `--mode dom` was tedious to type under an auto default; if `dom`
   becomes the default it is pointless, and if `article` does it stays
   useful.
5. **`PageProbe.word_count` is already dead.** Nothing in `ab/` reads it;
   `classify` was its only consumer. Removing it also means `probe` no
   longer needs the extraction handed to it. Independent of the rest of
   this ticket and true today.

## What 025 left here

[Whether dom alone is enough](025-whether-dom-alone-is-enough.md) closed
without deleting this ticket's central question: `article` stays, so there are
still two modes and still a default to choose. It leaves one argument for
question 1, and it comes with an expiry date.

**For `article`, while the root is broken.** On americanthinker `dom` returns
273 characters -- a sidebar promo card -- because `_ROOTS` takes the first
`<article>` of thirty. `auto` hides it today only by accident: `dom` measures
11 words, under `_MIN_COMPARABLE_WORDS`, so `choose` discards it. That floor
goes away with `auto`, which is why this ticket is blocked on
[028](028-the-root-heuristic-picks-a-decoy.md).

**The expiry.** 028 removes the condition. Once the root picks the real
container, "with the root broken `article` is safer by a wide margin" is no
longer an argument for anything, and question 1 is live again on its full
case -- including *required, no default*, which this ticket calls the honest
reading of [011](011-listing-clears-the-yield-floor.md) and which nothing has
yet argued against on its own terms. Do not read 025 as having settled it.

## Answer

**`mode` is required at both doors.** `ExtractMode` has two members, `extract`
is a two-armed match, and nothing in the tool chooses between them any more:

    fetch(url, mode)                      # MCP: required: ['url', 'mode']
    script(source, mode)                  # MCP: required: ['source', 'mode']
    agent-browser fetch URL --mode dom    # CLI: [required]

Out, as the ticket listed: `ExtractMode.AUTO`, `choose`,
`_ARTICLE_YIELD_FLOOR`, `_MIN_COMPARABLE_WORDS`. Also out, found while
removing them: `Settings.default_extract_mode` and `AGENT_BROWSER_EXTRACT`,
which no module had ever read -- a setting whose only value was the default it
carried, and that default was `auto`.

### Question 1: required, no default

Chosen over both defaults, on 011's own terms. The argument against it is that
it breaks every call omitting the argument and leaves a caller who does not
know with no fallback -- but a caller who does not know is exactly the case
`auto` served badly, and served *silently*. There is no third thing to guess
with; there is only whether the guess is made here or asked for. The break is
real and is the point: a call that omits `mode` now fails at the door instead
of quietly returning a footer.

`article`-by-default lost because it makes the majority case work and the
listing case fail in the one way this whole thread has been about -- content
present, dropped, nothing said. `dom`-by-default is now a defensible option in
a way it was not when the ticket was written (028 fixed the root, 025 gave
`dom` headings, lists and fences), and it loses only because the failure it
trades to is quieter noise on every document rather than a demand to think
once.

**The cost, stated:** `script` with `read_page=False` must still pass a `mode`
it will not use. Defaulting it for that one case would put the guess back in
the tool for the case where it matters least, so it stays required.

### Question 2: what the description carries instead

Two lines at both doors, and they say what `choose` was trying to compute:
`article` removes boilerplate and is right for a document -- an article, a
post, a docs page; `dom` keeps every visible line and is right for a listing,
feed, profile or search result, where `article` throws the cards away and
returns the footer. Naming the failure is the half that matters. The mode
table in the README gained the same column.

### Question 3: carried to 022, as the ticket decided

`word_count` survives as a display field on `Fetched` and nothing reads it to
decide anything. Whether it stays a word count, becomes a character count, or
stops being reported is [Drop ICU](022-drop-icu.md), which this unblocks.
`unlinked` and its test stay meanwhile: the number is still reported, and link
markup must not inflate it.

### Question 4: `--dom` is gone

It existed to shorten `--mode dom` under an `auto` default. With `mode`
required there is nothing to shorten past -- `--dom` and `--mode article` are
the same length of thought -- and two spellings of one argument is the drift
[One description, two doors](026-one-description-two-doors.md) is about.

### Question 5: `PageProbe.word_count` is gone, and could not be otherwise

Removed, along with the `extraction` argument `probe.probe` only needed to
compute it. This is more than tidying: while the field existed, the same page
could be probed with two different numbers depending on the caller's `mode` --
a presentation choice reaching into a verdict, which is 005's own defect. It
is now unrepresentable. `test_the_mode_can_no_longer_change_the_verdict` was
deleted for that reason and the reason is recorded in the module docstring;
the test copied a field that no longer exists.

### What was verified

`nix flake check` green (42 tests), `mypy --strict` clean, and both doors
exercised live: `fetch https://example.com --mode article` (17 words,
`mode_used: article`) and a `script` with `--mode dom` returning the same page
with its `Learn more` link intact. `tests/test_extract.py` kept its two `tidy`
tests and lost the four that pinned `choose`'s floors; `tests/test_detect.py`
lost the word counts from its fixtures.
