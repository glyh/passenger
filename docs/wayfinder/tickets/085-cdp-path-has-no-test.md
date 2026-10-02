---
id: 085
title: The CDP path has no test, and it is the one a runtime bump breaks
labels: [wayfinder:task]
status: open
assignee:
blocked_by: []
---

## Question

The three runtime primitives this tool cannot work without have no test here,
and one of them broke under a runtime bump without anything noticing.

Measured 2026-10-01: `playwright-core`'s `chromium.connectOverCDP` works under
Node 24.19.0 and **fails under bun 1.3.14** — `Timeout 30000ms exceeded`, from a
`ws` connect that never completes — because bun's `node:http` client did not
emit `'upgrade'` for a `101 Switching Protocols`. It works again on 1.4.2.
Nothing in `test/` or `live/` would have caught any part of that; it took a
throwaway probe written for the question.

The door this tool offers is `script`, and `script` is Playwright over CDP plus
`node:vm` plus `node:sqlite`. When a runtime or packaging change breaks one of
those there is no compile error and no failing test — there is a tool that
answers every call with a timeout, and the first symptom is a caller waiting.

## Direction

A `live/` check, because it needs a browser — CLAUDE.md's rule, and the reason
the other four live checks exist. Smallest real exercise of each primitive,
against a Chrome it starts itself:

- `chromium.connectOverCDP` — the call the tool makes, not `launch()`
- a page from the *attached* browser: `setContent` plus a locator read,
  `evaluate`, a `goto` then a read, and a `screenshot` **byte count**, since
  binary frames over the CDP pipe catch transport faults that small JSON
  replies hide
- `node:vm` `createContext` + `runInContext` returning a value — the script
  door itself
- a `node:sqlite` `DatabaseSync` round-trip

**It must not use port 9222 or the default state dir.** `LiveSession` and
`LiveTargets` already expect a Chrome on 9222, which is somebody's live session
with their logins in it; a ringer that can disturb one is worse than no ringer.
Start its own Chrome on a spare port under its own `--user-data-dir` and its own
`PASSENGER_STATE`, and kill both on the way out.

## Acceptance

- `node live/LiveCdp.res.mjs` passes on node, with a header saying what it needs
  and why it cannot be a test — the convention every file in `live/` follows.
- The same file passes under **bun 1.4.2** and fails under **1.3.14**. That is
  the point: it turns [083](083-one-file-with-bun.md)'s version floor into
  something enforceable rather than something written down.
- No stray process, port or state dir survives a run.

## Not this

Not the extraction walker — that is [043](043-tidy-hides-walker-differences.md),
and its subject is `skills/`, not the runtime. Not 083's packaging work.
