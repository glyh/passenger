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
