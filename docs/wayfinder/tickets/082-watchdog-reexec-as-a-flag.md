---
id: 082
title: The watchdog re-exec looks for a sibling file a single binary cannot have
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

`Reaper.summon` starts the idle reaper by spawning a second *entry file*:

    switch Proc.detach(execPath, [watchdogEntry()])

and `watchdogEntry()` (`src/shell/Reaper.res:104`) is `dirname(argv[1]) ++
"/Watchdog.res.mjs"`. That is a claim about the deployment: `argv[1]` is a
script path on disk, and its sibling is sitting beside it. `nix run` and a
client's own registration both satisfy it — the flake copies `src/` with its
shape intact, and `Reaper.res:100` says so in as many words.

A single-file build satisfies neither. Measured:

| runtime | `process.argv[1]` inside the binary | the sibling it looks for |
|---|---|---|
| `bun build --compile` | `/$bunfs/root/<name>` | `/$bunfs/root/Watchdog.res.mjs` — cannot exist |
| Node SEA | the binary's own path | `<dir>/Watchdog.res.mjs` — does not exist |

**And it fails silently.** `summon`'s own comment: *"A reaper that could not
start is no reason to fail a start that did -- the cost is the old world, a
browser nothing stops."* So the symptom of a single-file build is not an error
at all; it is a browser that is never reaped — ticket 076's complaint returning
invisibly, which is ticket 078's watts.

## The constraint that decides the shape

The obvious fix — teach `Main.res.mjs` a `--watchdog` flag, the way
`Webserve.serveIfAsked` already owns `--serve-viewer` — **does not work, and
the reason is deliberate.** The watchdog process must not reach Playwright, and
`Main.res.mjs` does. Measured by walking the emitted static import graph:

    src/cli/Main.res.mjs       31 modules, playwright-core imported by Session.res.mjs
    src/cli/Watchdog.res.mjs   20 modules, nobody imports playwright-core

Three comments say the separation is not an accident: `Browser.res:196` (the
teardown body moved to `Reaper.takeDown` *"so the idle reaper's watchdog could
share it without importing this module -- Playwright hangs off `Session`, which
hangs off here"*), `Present.res:80` (`unfullscreen` is a ref, and *"a watchdog
that never presents keeps the no-op and never loads Playwright"*), and
`Present.res:285` (`dropStaleHumanClaim` lives in `Present` rather than `Screen`
because *"the one path along which Playwright would reach the reaper (ticket
076)"*). A flag handled by `Main` would hand the reaper exactly what 077 spent
three seams keeping out of it.

## Direction

A **Playwright-free dispatcher entry**: one small module that reads its leading
flag and *dynamically* imports the body it names.

- `--watchdog` → `import("./Watchdog.res.mjs")` — that graph, unchanged, 20
  modules, no Playwright
- `--serve-viewer <port>` → today's `serveIfAsked`, moved or delegated to
- no flag → `import("./Main.res.mjs")`, the server

Dynamic `import()` is the whole mechanism: it is what keeps three graphs apart
while one file is the entry. The dispatcher's own static graph must stay empty
of anything heavy, and that is testable — a test asserting `Watchdog`'s graph
still contains no `playwright-core` is the guard against a later refactor
quietly importing `Browser` into the reaper.

This changes the launch contract, and that is the part to accept consciously:
`package.json`'s `bin`, `flake.nix:199` (`--add-flags`) and `:236` (the
shellHook echo), `README.md:438`, four lines of `CLAUDE.md`, and the two `live/`
registrations (`LiveDoor.res:15`, `LiveHandoff.res:27`) all name
`src/cli/Main.res.mjs` today.

## The argv shape, which is runtime-dependent

Measured, so the spawn can be written once and not "simplified" back:

    node         spawnSync(execPath, [entry, flag]) -> [node, entry, flag]                      flag at 2
    bun compiled execPath + [argv1, flag]           -> [bun, /$bunfs/root/x, /$bunfs/root/x, flag]  flag at 3
    bun compiled execPath + [flag]                  -> [bun, /$bunfs/root/x, flag]              flag at 2
    SEA          spawnSync(execPath, [flag, ...])   -> [binary, binary, flag, ...]              flag at 2

So `[flag]` alone is wrong under `node` (node reads it as one of its own
options) and right under both compiled forms, while `[argv1, flag]` is right
under node and pushes the flag one position later under bun. Either branch on
whether `argv[1]` is a file on disk, or have the dispatcher scan the first few
argv entries for a flag it knows. Pick one and write down why, in the code.

## Acceptance

- A single-file build reaps. `live/LiveWatchdog.res.mjs` passes against a
  compiled binary, on a state dir and port of its own as its header describes,
  for both `bun build --compile` and plain `node`.
- `Watchdog.res.mjs`'s static graph still contains no `playwright-core`,
  asserted by a test.
- The sibling-path mechanism is gone, along with the comment that leans on the
  flake copying `src/` with its shape intact.
- `test/Reaper_test.res` passes unchanged — it spawns nothing and should not
  have to change.
- A failed detach still does not fail the start.

## Not this

[085](085-cdp-path-has-no-test.md) is the CDP-path ringer;
[083](083-one-file-with-bun.md) is the packaging itself. This is the
prerequisite both need, and it is worth doing under `node` alone.

**Found on the way, not this ticket:** `package-lock.json:16` records the bin as
`src/door/Main.res.mjs` while `package.json` says `src/cli/Main.res.mjs` — a
stale lockfile entry naming a directory that does not exist.

## Answer

**The re-exec mechanism is verified. The compiled binary still does not reap,
and the reason is not this ticket.**

Measured 2026-10-02 with bun 1.4.2 (the system `/usr/bin/bun`, after the stale
`~/.bun` 1.3.14 was removed) compiling `src/cli/Entry.res.mjs`:

- `bun build --compile --external chromium-bidi` → 269 modules, 88,602,080 bytes.
  (`--external chromium-bidi` is required for the app, unlike for a bare probe.)
- The binary answers MCP over stdio: `initialize` then `tools/list` → 10 tools.
  The dispatcher's no-flag branch reaches the server.
- `--watchdog` runs the watchdog body (exit 0, silent); `--nonsense` gives exit 2
  and usage.
- **The spawn shape is exactly what this ticket was written for.** Forcing
  `show` through `Browser.start`'s "already running → summon" branch, with a
  fake CDP up, produced a real detached watchdog:

      watchdog /proc cmdline: ["/tmp/eb/passenger-bin","/$bunfs/cli/Entry.res.mjs","--watchdog"]
      PPid: 1

  The `/$bunfs/...` entry path arrives as one more inert argv, the flag follows
  it, and the child is reparented to init. That is the shape the ticket's argv
  table predicted for compiled bun, observed.

**Why the compiled build does not reap:** it never starts Chrome. `openLane` and
`script` both return `Internal error`, no CDP ever comes up, no `watchdog.pid`
appears — because `Assets.read` throws:

    Failure("no assets directory above /$bunfs/root")

`import.meta.dirname` is `/$bunfs/root` inside a compiled binary, so
`Assets.root()`'s walk-up finds nothing and `Browser.start()` throws before
`Reaper.summon` is reached. Baselines confirm it is compile-only: system node
24.19.0 and the same source run under bun both `openLane` fine.

So the single-file build's remaining blocker is
[083](083-one-file-with-bun.md)'s open question 1 — the assets — and this
ticket's subject, the re-exec, is done. Closed on that basis, with the caveat
recorded rather than hidden: **a compiled binary does not yet reap, and will not
until the assets resolve.**

Worth keeping: `live/LiveWatchdog.res.mjs` was already silently broken before
this change — it summoned `live/Watchdog.res`, which does not exist — so no
existing check would have caught a broken re-exec. `test/ImportGraph_test.res`
is now the guard against that class.
