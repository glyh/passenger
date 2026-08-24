---
id: 043
title: tidy() normalises away the differences the walker suite would catch
labels: [wayfinder:task]
status: open
assignee:
blocked_by: []
---

## Question


*Filed for later. Nothing is broken in production; this is about what the tests
can see.*

Every test in `tests/test_walker.py` enters through `dom_text`, deliberately:
[001](001-testing-the-shells.md) refused a seam into the JavaScript and
[034](034-broken-walker-passes-its-tests.md) strengthened the argument, because
a seam lets a test pass against a mock and fail against Chrome. That rule is
right and this ticket does not propose breaking it.

But `dom_text` is `evaluate(walker)` followed by `tidy(raw)`, and `tidy`
normalises hard: it collapses runs of spaces and tabs, `strip()`s every line,
drops blank runs to a single blank, and `strip()`s the whole result. **Anything
the walker gets wrong that `tidy` would have fixed anyway is invisible to all
thirteen tests.**

**Measured, by accident.** While porting the walker to F# for
[023](023-rewriting-into-csharp.md), the port passed **13/13** while its raw
output was *not* the same as `walker.js`'s. `walker.js` squashes whitespace in a
text node without trimming it -- only `label()` trims -- and the port used one
function for both, so it dropped the trailing space that separates a text node
from what follows. Found by diffing raw `evaluate` output during a benchmark;
the suite never had a chance to see it.

That specific bug was in the port and is fixed. What it exposes is a property of
the suite, and the next rewrite -- in any language -- hits it again.

**Why this is "for later" rather than now.** `tidy` runs in production too, so a
walker that emits a stray space produces byte-identical output to one that does
not. Nothing a caller receives is affected. This is test fidelity, and the cost
of it is paid only when somebody rewrites the walker.

To decide:

1. **Whether raw output can be pinned without a seam.** The obvious move -- a
   test that reads the walker's untidied output -- is exactly the seam 001 and
   034 refused. Whether a characterisation test can live somewhere honest (a
   second production call site? `dom_text(page, tidy=False)`, which is a seam
   wearing a parameter?) is the real question, and "no, document it instead" is
   an acceptable answer.
2. **Whether `tidy` is doing too much.** It exists for what `innerText` leaves
   behind. If the walker's own output no longer needs line-level `strip()` and
   space collapsing, then the walker is being graded on a curve for no reason,
   and narrowing `tidy` would make the suite sharper without any new test.
   Worth measuring what `tidy` actually changes on the fixture set today.
3. **Whether whitespace fidelity is worth having at all.** A defensible answer
   is that the walker's contract *is* its tidied output, in which case this is
   not a gap but the intended boundary -- and the thing to fix is that nobody
   wrote that down, so a rewriter assumes byte-fidelity is the bar.
4. **What else `tidy` could be hiding.** Trailing whitespace is the case that
   was caught. Blank-run collapsing hides missing and spurious block boundaries
   equally, and those are `nl()` bugs -- which is closer to something a caller
   would notice.

## Blocked on 047, and mostly answered by it

*Recorded 2026-08-24.* [Retire fetch](046-retire-fetch.md) moves `tidy()` into
`walker.js`, so this ticket must not be worked before
[047](047-one-door-script.md) lands -- the thing it is about changes shape.

What 047 settles, by construction rather than by argument:

- **Decision 3 is answered.** The walker's contract *is* its tidied output.
  After the move the raw walk exists nowhere outside the function, so there is
  no other form for a contract to be about. The gap this ticket named -- that
  nobody wrote that down, so a rewriter assumes byte-fidelity is the bar -- is
  closed by the code saying it.
- **Decisions 1 and 2 are moot.** There is no raw output to pin, so the seam
  question does not arise; and `tidy` stops being a separable pass whose
  necessity can be measured against the walker's output, because it *is* the
  walker's output.

**What survives, and is why this stays open.** Decision 4: normalisation still
hides more than trailing whitespace. Collapsing blank runs masks missing and
spurious block boundaries equally, and those are `nl()` bugs -- closer to
something a caller would notice than the stray space that started this. That
question is unchanged by the move, and after 047 it is the whole ticket.

## The suite this is about no longer exists

*Recorded 2026-08-24.* [Delete the Python door](053-delete-the-python-door.md)
took `tests/test_walker.py` with it, along with `dom_text` and the `tidy` call
site this ticket measures. Nothing replaced them: `tests/Passenger.Tests/` does
not mention the walker at any name, so **the walker has no tests at all**, and
`walker.js` is the only file in `skills/using-passenger/` that nothing exercises.

`blocked_by: [047]` is cleared -- 047 landed, and everything it settled above
stands. Decision 3 stays answered (the walker's contract is its tidied output,
because after the move there is no other form). Decisions 1 and 2 stay moot.

What this ticket becomes is one question, and it is bigger than the one it
started as:

**Does the walker get a suite again, and in what?** Thirteen tests entering
through `dom_text` were the thing whose fidelity was in doubt; zero tests have no
fidelity to argue about. The constraint that shaped them survives the port
intact -- [001](001-testing-the-shells.md) and
[034](034-broken-walker-passes-its-tests.md) refused a seam into the JavaScript
because a seam lets a test pass against a mock and fail against Chrome, and
[028](028-the-root-heuristic-picks-a-decoy.md) had already pinned a chromium in
the flake so a test can start a real browser. So the honest shape is a C# test
that launches Chrome, loads a fixture, evaluates `walker.js` off disk exactly as
the skill's recipe does, and asserts on what comes back. That also happens to be
the only way to assert the two properties other open tickets now want:

- a walker that survives a JSON round trip ([052](052-walker-escapes-do-not-survive-transport.md)),
- footnotes surviving the strip list ([051](051-walker-strips-asides.md)).

Decision 4 -- that collapsing blank runs hides missing and spurious block
boundaries equally, which are `nl()` bugs a caller would notice -- is unchanged
and becomes the first thing such a suite should be pointed at, rather than the
whole ticket.

Note the asymmetry that makes this less urgent than it sounds and more urgent
than it was: the walker is no longer production code. It ships as a recipe the
caller runs, so a defect in it costs an agent a rework call rather than
corrupting a reply -- but by the same token nothing in this repo's build can
fail because of it, and 051 and 052 were both found by an eval rather than by
the suite.

*Renamed 2026-08-24.* `skills/using-passenger/walker.js` is now
`skills/using-passenger/markdown.js`. Every `walker.js` above means that
file; the line numbers are unchanged apart from its header comment, which
was rewritten in the same commit. The traversal is still called a walk.
