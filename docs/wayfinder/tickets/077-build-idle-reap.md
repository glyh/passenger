---
id: 077
title: Build the idle reap
labels: [wayfinder:task]
status: open
assignee:
blocked_by: []
---

## Question

[076](076-idle-browser-reaper.md) settled the design; this builds it. The
decisions, in the shape the build needs them:

- `Config.idleStopS` -- `PASSENGER_IDLE_STOP`, seconds, default 10800 (3h),
  `0` disables, bounds 0..2147483647. Read through the `ref` like every
  setting, so a test can point it at 2.
- The reaping decision is one pure function -- facts in (now, newest touch,
  screen claims, occupied lanes and whether the occupied question *answered*,
  calls in flight in this process), verdict out (`leave`, `wait`, `fire`) --
  testable without a browser, in the `Detect`/`Lanes` style. A shell wrapper
  in a new `Reaper.res` gathers the facts; `Main.serve` owns the lifecycle
  (the interval, the transport-close hook, the exits).
- The linger: on transport close with the browser up and the reaper enabled,
  the serve process stays alive on a ~60s `Timers` interval (not unref'd --
  after stdio closes it is the only thing holding the event loop, which is
  the point). Each tick while the browser is up runs the usual sweep; when
  the decision says fire, run the shared teardown, write the tombstone
  *before* tearing down, and `exit(0)`. Browser down at a tick post-disconnect
  is also `exit(0)`. Signals exit without teardown. One stderr line at
  linger-start, since a human who ran `serve` by hand is otherwise left
  watching a process that will not die.
- The shared teardown: `Present.select().dismiss()`, kill the recorded viewer
  server pid (so `Webserve.ensure` must start recording it, symmetric with
  `recordViewer`; no cmdline sweep -- that scar is written in
  `Present.dismiss`), then `Browser.stop`. `passenger stop` calls the same
  function and thereby stops leaving the viewer window and the page server
  behind on `--force`.
- The tombstone: written to the state dir at reap time ("stopped idle at T
  after Ns of no calls"); read by `browserStatus` (a `lastIdleStop` field)
  and by `laneNotFound` (decorated detail); cleared by a human `passenger
  stop`, overwritten by the next reap.
- Docstrings state the contract where callers hold ids (`openLane`, `setTtl`:
  the browser itself stops after `PASSENGER_IDLE_STOP` of no calls anywhere);
  the skill's troubleshooting gets the operating knowledge. No notification.
- Tests: the decision function and the sweep-on-tick against the movable
  clock, unit; the linger-and-exit lifecycle in `live/` (needs a browser,
  like the rest of that directory).
