---
id: 077
title: Build the idle reap
labels: [wayfinder:task]
status: closed
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

## Answer

Built, as 076 settled it. `src/shell/Reaper.res` holds the rules and the
shared teardown; `src/cli/Watchdog.res` is the detached carrier;
`test/Reaper_test.res` crosses the horizon in a line and
`live/LiveWatchdog.res` spawns the real thing on a two-second setting.

Three things the ticket could not have named, found while wiring it:

**The cycle.** `Reaper` needs `Present` for `dismiss`, and `Present` reached
`Browser.unfullscreen` -- which is Playwright, and is exactly what the
watchdog cannot import. Rather than move `prepared`, `Present.unfullscreen`
became a ref that `Browser` fills in when it loads, the same seam
`Lanes.chrome` already is. A process that never presents keeps the no-op and
never loads Playwright; presenting is always downstream of `Browser`, so by
the time any `present()` runs the real body is in there.

**The sweep moved twice.** `Main.housekeep` held the collect-and-dismiss
pair; `Reaper.sweepPresentation` holds it now and both callers run the same
one. That is what makes `openLane`'s promise -- "collects itself after 30
minutes of no calls" -- true with no call arriving, which it had not been.

**`dropStaleHumanClaim` has three callers now**, so it moved from `Screen`
to `Present` for the same reason: `Screen` imports `Browser`.

The tombstone is delivered where the ticket said, in the `LaneNotFound`
branch of `Main`'s error boundary -- taken and deleted in one breath -- and
read without consuming by `browserStatus` under `lastIdleStop`.
