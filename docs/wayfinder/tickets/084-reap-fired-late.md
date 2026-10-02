---
id: 084
title: A reap fired 25 minutes past a horizon the tick cannot explain
labels: [wayfinder:research]
status: open
assignee:
blocked_by: []
---

## Question

A reap fired **25 minutes late**, and the tick cannot account for it. From
`browserStatus` on 2026-10-01, after the browser had been stopped:

    lastIdleStop: "browser stopped at 2026-10-01T08:04:08.293Z
                   -- nobody had used it for 205 min"

The horizon in effect was 180 minutes — the old `10800` default, because
`idleStopS` is read in `Reaper.summon` (`Reaper.res:119`) and so is **captured
by the watchdog process at spawn**. The watchdog that fired predated 081's move
to 2700. `Watchdog.tickMs` is `60_000` (`Watchdog.res:24`), so a 180-minute
horizon should have fired within a minute of it passing, not twenty-five.

Alongside that, one design fact worth writing down before it is rediscovered as
a bug: **changing `PASSENGER_IDLE_STOP` — including by changing its default —
does not affect a browser whose watchdog is already running.** The new value
applies from the next Chrome start. 081's answer does not say so, and a reader
who changes the default and watches three hours go by will conclude the change
did not work.

## Suspects, none of them measured

1. **The guards held it off, silently.** `Reaper.decide` requires
   `claims->Array.length == 0 && occupied->Array.length == 0` *as well as* the
   horizon. A lane holding a live tab, or a screen claim, defers the reap and
   records nothing — and the tombstone reports only the idle figure, so the
   deferral is invisible from outside.
2. **The tick threw for a stretch.** `Watchdog.res:82` — *"A tick that throws
   does not end the watch: sqlite is contended by every..."* — so a contended
   registry retried once a minute looks from outside exactly like a late reap,
   and nothing counts the failures.
3. **The stop sequence is slow.** The reap pings the desktop, dismisses, and
   runs the shared teardown. If the tombstone's `now` is the *write* time rather
   than the *decision* time, that difference is teardown latency, not idleness —
   in which case the number in the message is measuring the wrong thing.
4. **The 205 is honest and the arithmetic is elsewhere.** 081 documents that a
   swept lane's row is deleted, so `MAX(touched_at)` falls back to older
   reserved rows and idle *"keeps growing across the sweep"*. So 205 may be
   true of a fallback row while the horizon that actually mattered was a
   different one.

## To decide

- **What the tombstone should say.** Today it carries one number with one
  meaning. Either it reports both times — decided-at and written-at — and the
  guards' state at the decision, or the next person re-derives all of this from
  nothing.
- **Whether a deferred reap should be visible.** A reap held off by an occupied
  lane is correct and silent by design; a reap held off for 25 minutes by
  something that is *not* a lane is watts. Only one of those deserves silence,
  and 078 is the ticket that says so.

## Acceptance

A number rather than a theory: the 25 minutes attributed to one suspect by a
measurement someone else can rerun, and the tombstone carrying whatever made
the attribution possible. If it turns out to be reporting only, say so and
close this; if it is a real delay, the fix belongs with 078.

## Constraints

Up to 25 minutes is up to 25 minutes of an unthrottled browser per reap — this
is a 078 ticket wearing 084's name. Do not reopen "stop Chrome more often":
076 answered that.
