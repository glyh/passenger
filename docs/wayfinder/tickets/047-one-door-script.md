---
id: 047
title: Delete fetch, and make script the only door
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question


The work decided by [Retire fetch](046-retire-fetch.md). **That ticket holds the
design and the reasons; this one does not restate them.**

Mostly deletion. `script` already opens a fresh tab when `tab` is omitted, can
`page.goto` itself, and already classifies its ending page through the same
`service.inspect` that `fetch` used -- so the capability exists and what is left
is removing the other door and the extraction behind it.

## What to do

1. **Delete `fetch`** from `mcp_server.py` and from the CLI. Eleven MCP tools
   become ten.
2. **Delete the extractors.** `dom_text`, `article_text`, `ExtractMode`, the
   `mode` parameter everywhere, and `read(page)` from `script`'s scope.
   trafilatura and justext leave `pyproject.toml`.
3. **Move the walker to `skills/using-passenger/walker.js`**, a file in the
   skill directory rather than a fenced block in `SKILL.md`. Repoint
   `tests/test_walker.py` at it; the fixtures and the real-browser harness do
   not change.
4. **Keep the measurements.** `Blocked` untouched. `Fetched` loses `markdown`
   and `mode_used` and becomes what it always was underneath -- a measurement of
   the ending page. Rename it if `Fetched` stops making sense with no fetch.
5. **`char_count` from `document.body.innerText`**, not from an extraction.
   Close [039](039-extractor-returns-nothing-on-12306.md) when this lands: it
   was reopened-in-spirit by this change and fixed by it.
6. **Rewrite `SKILL.md`.** It currently teaches `fetch` first -- "a fetch is one
   screen", mode selection, `blocked`. All of that has to be re-taught around
   one door, and the walker gets a section saying when to reach for it.

## To decide while doing it

1. ~~**`tidy()`**~~ **Decided: into `walker.js`.** Three notes for whoever does
   it.

   **It gets simpler on the way in, not harder.** `tidy` re-detects fenced
   blocks by matching lines that are exactly ``` -- a string search for a marker
   the walker itself emitted moments earlier. Inside the walker the `PRE` state
   is already tracked (`isPre`), so fence-awareness stops being a detection
   problem and becomes a variable that is already in scope.

   **Some of it may already be dead.** Its docstring says it collapses "the
   blank runs and stray whitespace *innerText* leaves" -- but the walk does not
   read `innerText` for text nodes, it reads `nodeValue` and squashes runs
   itself (`label()` is the only `innerText` caller). So part of `tidy` is
   cleaning up after a mechanism the walker stopped using. Measure what it still
   changes on the fixture set before porting it line for line; the honest port
   may be half of it.

   **It makes the tidied form the only form.** Today the raw walk exists for a
   moment between `page.evaluate` and `tidy`. Afterwards it exists nowhere
   outside the function, which answers
   [043](043-tidy-hides-walker-differences.md)'s third decision by construction:
   the walker's contract *is* its tidied output, because there is no other
   output to have a contract about.
2. **Whether `extract.py` survives at all** once its callers go.
3. **What the skill says about failure.** `dom_text` degraded to
   `inner_text("body")` on a page that could not answer; a recipe has no such
   wrapper.

## Tickets this closes or changes

- [Build drop_run](045-build-drop-run.md) -- **closed by this, unstarted.** It
  was a feature on a mode that will not exist. Its acceptance set survives and
  is reusable.
- [tidy() normalises away the differences the walker suite would
  catch](043-tidy-hides-walker-differences.md) -- **reshaped, not closed.** If
  `tidy` moves into the walker the blind spot moves with it; if it goes, the
  ticket is moot. 045 was blocked on it; nothing is now.
- [Whether this moves to C#](023-rewriting-into-csharp.md) -- **loses its
  expensive half.** No trafilatura port. Update its second phase.
- [One description, two doors](026-one-description-two-doors.md) -- most of the
  drift it catalogues is `fetch`'s parameters, and both doors now carry the same
  two verbs. Re-read it after this lands; it may be much smaller or moot.

## Answer

**Done.** `script` is the only door at both surfaces; `fetch`, `article`, `dom`,
`ExtractMode`, `Extraction`, `FetchRequest`, `read(page)` and trafilatura are
gone. Eleven MCP tools are ten. Net −239 lines across the change, and the
project now runs no extraction at all.

Verified end to end through the CLI against a live page, both recipes exactly as
the skill writes them: `page.inner_text('body')`, and the walker read from
`skills/using-passenger/walker.js` and evaluated, which returned markdown with
its heading and a resolved link. 78 tests pass, `mypy --strict` is clean, and
trafilatura is out of the dev shell.

**What moved rather than went.** `tidy()` is inside the walker. The walker is
`skills/using-passenger/walker.js` with its own defaults for the strip selector
and the root list, callable with no arguments, and still tested in a real
browser against 028's fixtures. `Fetched` became `Measured`: url, title,
`char_count`, picture geometry, and nothing that interprets.

**Three things worth knowing that the ticket did not anticipate.**

1. **`char_count` is now `document.body.innerText`**, which closes
   [039](039-extractor-returns-nothing-on-12306.md) by construction rather than
   by fix. That ticket closed undone on a count of 0 for a page holding 2,647
   characters -- a number measuring the extractor while looking like it measured
   the page. There is no extractor to measure now.
2. **The walker's defaults needed a null guard, not a default parameter.**
   `page.evaluate(source)` with no argument sends *null*, so
   `([a, b] = []) => …` never fires and destructuring throws. Destructured
   inside the body instead.
3. **The tidy coverage gap was worse than recorded, and is now closed.** Across
   all thirteen existing walker tests, `tidy` only ever stripped leading and
   trailing whitespace; on real pages it collapses up to 140 blank runs and 201
   space runs in a single document. Four tests were added for the paths nothing
   reached -- and the blank-run one needed correcting first: an *empty* block
   produces no blank line at all, because `nl()` will not append a newline after
   a newline. Real pages get theirs from blocks holding whitespace.

**What `show_browser` gained**, being the one capability `fetch` had that
nothing else reached: `until="unblocked"`, which polls the named tab until the
vendor signature stops matching, beside the default that waits for the human to
close the viewer. `handoff.wait_for_human` became `wait_until_unblocked` and
stopped needing an extractor.

**Tickets this changed:**

- [039](039-extractor-returns-nothing-on-12306.md) -- **closed**, by
  construction.
- [Build drop_run](045-build-drop-run.md) -- was already closed as superseded.
- [043](043-tidy-hides-walker-differences.md) -- unblocked, and reshaped as
  predicted: `tidy` is in the walker, so its third decision is answered by
  construction and its first two are moot. What is left is decision 4.
- [023](023-rewriting-into-csharp.md) -- its second phase is marked overtaken.
  No trafilatura port, no justext, no XPath DOM library; the walker is
  JavaScript a port inherits unchanged.
- [026](026-one-description-two-doors.md) -- annotated. Nearly every parameter
  it catalogues was `fetch`'s, and the two doors now carry the same verbs. It
  may be closeable by subtraction.
