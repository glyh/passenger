---
id: 035
title: checkVisibility() catches only display:none
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

The walker filters invisible nodes with

    if (node.checkVisibility && !node.checkVisibility()) return;

Called with no arguments, `checkVisibility()` defaults `visibilityProperty`,
`opacityProperty` and `contentVisibilityAuto` all to **false**. It reports on
`display:none` and nothing else. Measured on a fixture page:

    display:none            filtered
    visibility:hidden       LEAKED
    opacity:0               LEAKED
    content-visibility      LEAKED

Three of the four ways a page hides something pass straight into the
extraction. Surfaced while writing the walker's tests in
[034](034-broken-walker-passes-its-tests.md), which pins the current
behaviour rather than changing it -- widening the filter changes what every
page returns, and that is a measurement, not a one-line edit.

[030](030-the-walker-reads-a-snapshot.md) assumed the opposite. Its
"what must survive the trip" list reads *"elements with `visibility:hidden`,
`opacity:0` or `content-visibility` still generate boxes, so the requested
computed styles have to cover them"* -- written as a constraint on a rewrite,
but only sensible if the current code already handles them. It does not, so
the rewrite would have faithfully preserved a gap nobody knew was there.

### Why this is not obviously a one-line fix

The obvious change is

    node.checkVisibility({visibilityProperty: true, opacityProperty: true,
                          contentVisibilityAuto: true})

and it may well be right. But it cannot be made on reasoning alone, for the
same reason [025](025-whether-dom-alone-is-enough.md) had to measure:

- **`opacity:0` is not only a hiding mechanism.** It is the resting state of
  an entrance animation, and on a page whose JavaScript has not finished the
  animation, the content that matters may be at zero opacity when `fetch`
  reads it -- `settle_ms` bounds the wait, it does not guarantee the page is
  done. Filtering it could turn a working page into an empty one, which is
  the failure mode this tool can least afford.
- **`content-visibility: auto` is a rendering optimisation**, applied to
  content that *is* there and is merely offscreen. Long documents and virtual
  lists use it deliberately. `contentVisibilityAuto: true` would drop exactly
  the below-the-fold body of a long article.
- **`visibility:hidden` is the safe one** and is likely correct on its own.

So the three options are not one switch. `visibilityProperty` alone,
`visibilityProperty` plus `opacityProperty`, and all three are three different
proposals with three different risks.

### What settles it

025's five pages are the acceptance set, as they were for
[028](028-the-root-heuristic-picks-a-decoy.md): run each variant against them
and compare character counts and diffs. A variant that changes nothing on all
five is not obviously worth taking; one that drops a hidden overlay and leaves
the bodies untouched is. Record it in `assets/035-*-findings.md` like 002, 004
and 015.

Whichever variant wins, the gap it closes gets a test in `test_walker.py`, and
`test_display_none_is_filtered_and_nothing_else_is` -- which currently asserts
the leak -- is rewritten rather than deleted, since the leak is what happened.

### Open

1. **Whether `trafilatura` has the same gap**, and whether that changes the
   answer. 025 recorded it swallowing gmw's overlay where `dom` dropped it, so
   the two extractors already differ here; widening `dom`'s filter widens that
   difference rather than creating it.
2. **Whether a fourth mechanism matters** -- `clip-path`, zero height with
   `overflow:hidden`, and text positioned offscreen are all in use as
   screen-reader-only idioms, and `checkVisibility()` reports on none of them
   under any option. Probably out of scope, but it should be said rather than
   assumed away.

## Answer

`visibilityProperty` taken. `opacityProperty` refused. `contentVisibilityAuto`
left alone.

    if (node.checkVisibility && !node.checkVisibility({visibilityProperty: true})) return;

Measured against 025's five pages and four more chosen for the risk rather
than the verdict; the full tables are in
[assets/035-checkvisibility-findings.md](../assets/035-checkvisibility-findings.md).

### What each option was worth

**`visibilityProperty` is free.** Across nine pages it removed two lines, both
on chinadaily, both hidden nav furniture -- `China Daily PDF` and `China Daily
E-paper` -- and touched no body text anywhere. Small, but it makes the call
mean what its name has always implied.

**`opacityProperty` is the one that had to be measured.** The concern written
above -- that `opacity:0` is also the resting state of an entrance animation --
turned out to understate it. The acceptance set was silent: three lines of
dialog chrome on americanthinker (`Link copied`, a login form's labels) and
nothing else on the other four. So the probe was the whole experiment, and
apple.com/macbook-pro answered it:

    A_today   13,081 characters
    C_vis_op   3,761 characters      -- 71% gone, 125 lines

and what went was body text, not furniture: `M5, M5 Pro, and M5 Max chips`,
`Battery life`, `macOS Tahoe`. Scroll-triggered reveal holds below-the-fold
content at `opacity: 0` until a reader arrives, and `fetch` is goto-settle-read
-- it never arrives. Three lines of chrome against most of a page is not a
trade, and the asymmetry is the argument: furniture surviving is a cost,
content vanishing is a lie.

**`contentVisibilityAuto` changed nothing anywhere it was tried**, and the page
chosen to exercise it -- MDN's own `content-visibility` article -- returned
zero characters through `dom` for unrelated reasons, so it was never really
exercised at all. Untested is not safe. Taking a change with no measured
benefit and a named risk, long documents deferring their body with exactly this
property, is the wrong direction.

### The open questions

1. **Whether trafilatura has the same gap.** Not chased. 025 already recorded
   the two extractors differing here, with trafilatura swallowing gmw's overlay
   where `dom` dropped it; widening `dom`'s filter by one option widens a
   difference that already existed rather than creating one. Whatever
   [029](029-one-extractor-instead-of-two.md) settles will answer it properly.
2. **A fourth mechanism** -- `clip-path`, zero height with `overflow:hidden`,
   text positioned offscreen. Still true, still unreported by
   `checkVisibility()` under any option, and now explicitly out of scope: the
   apple.com result says the danger is over-filtering, not under-filtering, so
   chasing more hiding mechanisms is chasing the wrong direction.

### Surfaced while doing this

`dom` returns **0 characters** on `developer.mozilla.org` and **91** on
`vercel.com/blog`. All four variants agree on both, so it is not a visibility
question -- both are JS-rendered pages where the walk finds nothing to walk.
Recorded in the findings rather than chased; whether `dom` should have anything
to say about a page like that is 029's ground.

### Tested

`test_display_none_is_filtered_and_nothing_else_is` was rewritten rather than
deleted, since the leak is what happened, and it now pins all three outcomes:
`display:none` and `visibility:hidden` filtered, `opacity:0` deliberately kept.
Its docstring carries the apple.com number, so the next person to reach for
`opacityProperty` meets the measurement before the option.

`nix flake check` green: 43 tests, `mypy --strict` clean over 20 files.
