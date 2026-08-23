---
id: 047
title: Delete fetch, and make script the only door
labels: [wayfinder:task]
status: open
assignee:
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

1. **`tidy()`** -- into the walker, into the recipe, or gone. See 046. Decide
   before step 3, because it changes what the file is.
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
