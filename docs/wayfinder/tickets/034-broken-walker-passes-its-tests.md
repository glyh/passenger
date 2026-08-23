---
id: 034
title: A broken walker passes its own tests
labels: [wayfinder:task]
status: open
assignee:
blocked_by: []
---

## Question

Replace `_DOM_JS`'s JavaScript with a syntax error and run the suite:

    1 failed, 2 passed

Two of the three walker tests pass with the walker completely dead. The reason
is the fallback in `dom_text`:

    try:
        raw = page.evaluate(_DOM_JS, [_STRIP, list(_ROOTS)])
    except Exception:
        raw = page.inner_text("body")

`inner_text("body")` still contains "The real piece." sixty times, so
`test_many_articles_are_a_listing_not_a_document` -- the test
[028](028-the-root-heuristic-picks-a-decoy.md) was written for -- passes on a
dead walker, and so does `test_an_empty_container_is_not_the_root`. Only
`test_a_single_article_is_still_the_root` catches it, and by accident: it
asserts `"Sidebar furniture" not in text`, and the sidebar happens to be in
the body.

This is [024](024-teardown-gives-up-quietly.md) in a different module. A
failure dressed as a success, and the tests that should have named it are the
things it hides behind.

Split out of [The walker reads a snapshot, not the
page](030-the-walker-reads-a-snapshot.md), which proposed rewriting the walker
into Python over a `DOMSnapshot` to make it testable. 030 was closed no: the
JavaScript is the one part of `extract.py` that survives the C# port
unchanged, and the harness it wanted already existed -- 028 built it and the
flake pins a chromium for it. The walker stays JavaScript in the page. What it
does not stay is untested and unreadable.

### The fallback stops hiding our bugs

Two distinct failures sit behind that `except`, and they deserve opposite
treatment:

- **The page cannot answer** -- a wedged renderer
  ([012](012-one-wedged-tab-bricks-every-call.md)), a navigation mid-flight, a
  closed target. Degrading to `inner_text` is right, and the caller gets
  something rather than an error. This is what the fallback was written for
  and it stays.
- **The walker is broken** -- a syntax error or a `TypeError` in our own code.
  This must never be swallowed. A bug in this repo that emits plausible prose
  is strictly worse than one that raises, because nothing downstream can tell.

Sniffing exception types does not separate them; playwright wraps both in the
same `Error`. Validating the walker once, on load, does -- and the walker
becoming a file is what makes that natural. A broken `walker.js` then fails at
a place that names it, and the runtime `except` is left holding only the
page-side failures it was written for.

In the tests, the fallback is poisoned outright: a fixture makes
`page.inner_text` raise for the duration of a walker test, so no test can pass
on degraded output again. That is a few lines, and it makes every test below
honest by construction rather than by each author remembering to assert
something `inner_text` could not have produced.

### The walker moves to `ab/walker.js`

It is ~120 lines inside `r"""..."""`, which survives only because no `"""`
appears in the JavaScript -- a docstring-style comment would truncate it
silently. In a file it gets highlighting, a formatter, and `node --check`, and
`extract.py` drops to roughly a hundred lines and reads as the shell it claims
to be.

The cost is a packaging failure mode the string cannot have.
`pythonImportsCheck` catches a missing dependency but not a data file absent
from the wheel -- the import succeeds and the first fetch fails -- and
`checks.default` runs pytest against `${source}`, the working tree, not the
built wheel, so neither gate would catch it. Closing that hole is part of this
ticket, not a follow-up.

Read once, at import, via `importlib.resources`, into a module constant --
exactly today's semantics, where `_DOM_JS` is fixed at import, and the natural
place for the load-time validation above. Reading per call was considered and
refused: it would make the walker hot-reloadable and make *which code ran*
unanswerable, which is a worse version of the map's stale-server fog rather
than a fix for it. The standing expectation is that a running server is
restarted after an edit, and that is now recorded rather than implied.

### Structure for reading, not for testing

The five nested closures (`push`, `mark`, `nl`, `label`, `walk`) become named
top-level functions inside the injected IIFE. No `export`, no module form, no
JavaScript test runner in the flake.

This repo has already ruled the same way once --
[001](001-testing-the-shells.md): *no seam for `_alive`; a real zombie is
`Popen(["true"])` unreaped, so the test runs against the actual `/proc` read.*
The argument is stronger here. `label()`'s entire behaviour is `innerText`,
`getAttribute` and a descendant query -- the browser. A seam would let a test
pass against a mock and fail against Chrome, which is the failure a seam
exists to prevent, inverted, and it is the seam that would tempt someone into
jsdom, where `innerText` and `checkVisibility` are not real.

`_STRIP` and `_ROOTS` stay in Python and stay arguments, as today. They are
the two things a reader looks for first, and a test that wants to pin the root
heuristic can vary them without touching the walker.

### Tested

Fixtures are synthetic minimal HTML with inline `style=` wherever the
behaviour under test is CSS-dependent, which is what `test_walker.py`'s own
docstring already claims -- *the smallest thing that reproduces a shape*.
Captured real pages were rejected on a mechanical point: `set_content` loads
no external CSS, so a saved page arrives without its stylesheet, and the
hardest scar below -- a hidden overlay -- would fail against a correct walker
and could only be made to pass by weakening the assertion. 025's five real
pages remain an acceptance run recorded in `assets/`, not a test; the suite
starts no real stack (001).

Inline in the test file until a fixture exceeds roughly ten lines;
`tests/fixtures/` is not created pre-emptively.

Each of these names a failure that happened:

1. **Block boundaries** ([007](007-links-lost-in-dom-mode.md)). `innerText` on
   a detached clone is `textContent`, so `dom` returned one unbroken run.
   Adjacent `<p>`s must come back separated. This is the scar `inner_text`
   most obviously fakes, so it is the one the poisoned fallback matters most
   for.
2. **Link targets** (007). `[label](url)` inline, resolved against the
   document and *not* normalised -- assert a signed query string survives
   byte-for-byte, since that is the specific thing 007 forbade. Plus
   `#section` skipped.
3. **The bare-URL anchor rule** (007). Distinct from 2: the href histogram
   keeps the one search result whose card is a bare cover image and drops the
   other nineteen cover anchors that repeat their card's title link. Two
   anchors to one href, one labelled -- the unlabelled one goes. One anchor,
   unlabelled -- it stays.
4. **The orphaned list marker** ([025](025-whether-dom-alone-is-enough.md)).
   An `<li>` whose first child is a block emitted `- ` alone on its own line,
   and on documentation most of them are.
5. **The unflushed marker** (025, same commit). A block that turns out to hold
   nothing must drop its pending marker, or it labels the next block's text.
   A different failure from 4, and a different assertion.
6. **Fence indentation from the walker's side** (025). `test_extract.py`
   covers `tidy`'s half; nothing covers the walker emitting the fence and
   carrying `PRE` whitespace into it. The scar was a Python sample flattened
   against its `def`.
7. **`checkVisibility()`** (025). Not a `dom` scar -- a trafilatura one. gmw's
   hidden WeChat share overlay is what 025 recorded trafilatura swallowing and
   `dom` correctly dropping, and that difference is part of why 025 kept both
   extractors. Needs `visibility:hidden` and `opacity:0` inline, since layout
   presence alone catches neither.
8. **Labels from `aria-label`, `title` and `img[alt]`**. The path
   `extract.py:105` reaches when `innerText` is empty. 030's own "what must
   survive" list omitted it, which is evidence enough that it is the part
   people forget exists.

Left out deliberately: heading levels, `OPAQUE` tag handling, and `_STRIP`
doing its job. They work, nothing has broken them, and adding them is the
coverage bar 001 refused.

### Order

All eight are written against the JavaScript as it stands today, and green,
*before* a line of it moves. A test written after a refactor pins the
refactor, not the behaviour.
