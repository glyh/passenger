---
id: 077
title: Build the idle reap
labels: [wayfinder:task]
status: open
assignee: lyh (via Claude)
blocked_by: []
---

## Question

[076](076-idle-browser-reaper.md), as amended by grilling, settled the
design; this builds it. The carrier is a detached watchdog, not a lingering
server -- the serve process is untouched.

- `Config.idleStopS` -- `PASSENGER_IDLE_STOP`, seconds, default 10800 (3h),
  `0` disables everything, bounds 0..2147483647. Read through the `ref`
  like every setting, so a test can point it at 2. The blind horizon is
  derived: 8x, a named constant, no second knob.
- The reaping decision is one pure function -- facts in (now, newest touch,
  screen claims, occupied lanes or `unknown` when Chrome does not answer,
  blind ticks so far), verdict out (`leave`, `wait`, `fire`, `fire-blind`)
  -- testable without a browser, in the `Detect`/`Lanes` style. A new
  `Reaper.res` in `src/shell/` gathers the facts; it imports sqlite and
  `Targets`, never `Pw`.
- The watchdog: detached at `Browser.start` (after Chrome is up; skipped if
  the recorded pid is alive), pid recorded in `watchdog.pid`, tick ~60s,
  stdio to `/dev/null`. Each tick: browser gone -> clear pid file, exit.
  Sweep on the tick while up. Sighted fire -> ping, tombstone, shared
  teardown, exit. Blind fire (8x continuous `unknown`) -> same, with the
  registry guards (claims) still honored.
- The ping: `Notify.desktop` only (no webhook, no stderr), best-effort,
  before tombstone and teardown.
- The shared teardown: `Present.select().dismiss()`, kill the recorded
  viewer-server pid (`Webserve.ensure` must start recording it, symmetric
  with `recordViewer`; no cmdline sweep), then `Browser.stop`.
  `passenger stop` calls the same function and thereby completes its
  inventory.
- The tombstone: written before teardown; **deliver-once** -- consumed only
  by the `laneNotFound` decoration (attached and deleted in the same
  breath), read passively by `browserStatus` (`lastIdleStop`), cleared by a
  human `passenger stop`, overwritten by the next reap. Never cleared by
  `Browser.start`.
- Docstrings state the contract where callers hold ids (`openLane`,
  `setTtl`: the browser itself stops after `PASSENGER_IDLE_STOP` of no
  calls anywhere); the skill's troubleshooting gets the operating
  knowledge.
- Tests: the decision function and the blind-tick arithmetic against the
  movable clock, unit; the watchdog lifecycle (spawn, single-instance,
  exit-on-down, ping-then-teardown) in `live/`, which is where things
  needing a real browser already live.
