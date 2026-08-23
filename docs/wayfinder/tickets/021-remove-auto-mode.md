---
id: 021
title: Remove auto mode
labels: [wayfinder:task]
status: open
assignee:
blocked_by: [025, 028]
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
