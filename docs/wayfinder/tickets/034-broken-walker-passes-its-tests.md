---
id: 034
title: A broken walker passes its own tests
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
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

## Answer

Done, and the measurement that opened the ticket now runs the other way.
Replacing the walker's JavaScript with a syntax error:

    before   1 failed, 2 passed
    after   13 failed

### The fallback is unreachable in a test, and unchanged in production

The `page` fixture replaces `page.inner_text` with something that raises. That
is the whole mechanism -- three lines -- and it is what makes every test below
honest by construction rather than by each author remembering to assert
something `inner_text("body")` could not have produced.

`dom_text`'s `except` stays exactly as it was. Ticket 012's wedged renderer
really does stop answering, and a caller is better served by degraded text
than by an exception. The docstring now says what the fallback is for and what
it must not do, and names the measurement, so the next person to widen that
`except` knows what it costs.

Load-time validation turned out to be unnecessary as a separate mechanism. A
syntax error in `walker.js` now fails thirteen tests in `nix flake check`,
which is the gate that matters; adding `node --check` would have put a node
toolchain in the flake to re-detect what the suite already catches.

### Eight tests, and five that were already there

Thirteen in `test_walker.py`, all through `dom_text`. The new ones: block
boundaries after the detached-clone bug (007), a relative href resolved
against a real document URL (007), a signed query string surviving
byte-for-byte (007), a fragment link emitted as prose rather than a link
(007), the histogram rule in both directions (007), labels from `aria-label` /
`title` / `img[alt]`, the orphaned list marker and its unflushed twin (025),
a fence keeping its indentation (025), and what `checkVisibility()` actually
filters.

One fixture is not `set_content`. Under it the document is `about:blank`,
where a relative href resolves to nothing `^https?:` matches -- so link
*resolution*, half of what 007 settled, was invisible to any test. A `served`
fixture fulfils a local route so one page has an origin and a directory,
offline.

Captured real pages were rejected on a mechanical point rather than a
preference: `set_content` loads no external CSS, so a saved page arrives
without the stylesheet, and every CSS-dependent behaviour becomes untestable
or -- worse -- passes for the wrong reason.

### `ab/walker.js`, and the packaging hole that was real

224 lines of `extract.py` became 115. The closures became named function
declarations; nothing was exported and no JavaScript runner entered the flake.

Equivalence was measured, not assumed: old and new evaluated against ten
fixtures -- the decoy page, blocks, links, labels, nested lists, headings,
`pre`, the three hiding mechanisms, the strip selectors, and
blockquote/details/figure -- byte-identical on all ten.

The packaging hole predicted above turned out to be more than theoretical.
`nix build` failed with `FileNotFoundError: .../ab/walker.js` on the first
attempt, because a flake's source is the git tree and the new file was
untracked. That is exactly the failure the read-at-import decision was
supposed to catch, caught by the mechanism it was supposed to be caught by --
both entry points import `ab.extract`, so `pythonImportsCheck` performs the
read. No new machinery was needed and none was added.

### Surfaced while doing this

`checkVisibility()` called with no arguments defaults `visibilityProperty`,
`opacityProperty` and `contentVisibilityAuto` to false, so it filters
`display:none` and nothing else -- `visibility:hidden`, `opacity:0` and
`content-visibility` all leak into every extraction today. 030 had assumed the
opposite and would have preserved the gap faithfully. Pinned here rather than
fixed, because widening the filter could drop an entrance animation's content
or a long article's below-the-fold body, and that is a measurement against
025's pages: [checkVisibility() catches only
display:none](035-checkvisibility-only-catches-display-none.md).

`nix flake check` green: 43 tests, `mypy --strict` clean over 20 files.
