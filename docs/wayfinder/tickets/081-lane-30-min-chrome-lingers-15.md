---
id: 081
title: A lane lives 30 minutes, and the browser lingers 15 more
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

The owner's ruling, 2026-10-something, in one breath: **"lane dies if not touched
in 30 min, chrome lingers 15 min."**

Two numbers, and only one of them is work.

- **The lane's 30 minutes is already true.** `Lanes.defaultTtlS = 1800`
  (`src/shell/Lanes.res:55`), unchanged by this ticket. What prompted the request
  was probably the *browser's* number, which is three hours, not the lane's.
- **The browser's number is not.** `Config.idleStopS` defaults to `10800`
  (`src/shell/Config.res:61`) — three hours. It becomes **2700 (45 min)**.

### Why 45 and not 15

Because the clock the reaper actually reads is not "how long has no lane
existed". It is `Lanes.newestTouch()` — `MAX(touched_at)` over the whole
registry (`src/shell/Lanes.res:291`), so the horizon counts from the last call
*any* lane made, and a lane is swept once `now - touched_at >= ttl_s`
(`Lanes.expired`, `:266`). One clock, two thresholds: the lane goes at 30, the
browser at 45. Fifteen minutes after the lane dies, in the case that matters —
a caller who made one call and left.

That is the whole arithmetic, and it depends on one fact worth writing down
here rather than rediscovering: the lane's row is *deleted* by the sweep, so
after it goes, `MAX(touched_at)` falls back to the reserved `orphan`/`human`
rows, whose stamps are older than the dead lane's. Idle time therefore keeps
growing across the sweep instead of resetting — the continuity the reaper's
read depends on. `newestTouch`'s "never empty in practice" comment is the same
fact seen from the other side.

## What it touches

One constant, and the prose that tells a caller what it means:

- `src/shell/Config.res:61` — `10800` → `2700`. The doc comment above it stays
  true as written ("How long the browser may sit with nobody using it") and the
  8x blind horizon is derived, so it becomes 6h: meant to be, and no second knob.
- `src/cli/Main.res:192` and `:207` — the `openLane`/`setTtl` docstrings say
  "3h by default" twice. Caller-facing, and wrong the moment the default moves.
- `README.md:349` — the env table's "(default 10800, three hours)".
- `skills/using-passenger/references/tabs-and-lanes.md:107,116` — "three hours
  by default", twice. Same two sentences, same fix.

`map.md:98` is the decisions-so-far record as it stood at 076 and is history —
append the closing line beside it, do not rewrite it.

## Answer

Built. `Config.idleStopS` defaults **2700 (45 minutes)**, and the five prose
sites that named the old number now name the new one: `Main.res:192,207` (both
`openLane`/`setTtl` docstrings), `README.md:349`, and the two sentences in
`tabs-and-lanes.md`. Acceptance grep over `src/`, `README.md` and `skills/`
returns nothing for `10800|three hours|3h`; `npm test` is 139/139.

Three things worth having on the record, found while doing it:

**It really is one constant, and that is a fact about `Reaper`, not luck.**
The blind horizon -- reaping a browser that has stopped answering -- is
`Reaper.blindMultiple = 8` multiplying whatever `idleStopS` holds, so it moved
with the constant to 6h and no second number had to be found. Had the 8x been
written out as `86400` anywhere, this ticket would have been a different ticket.

**Nothing pins the old default, so no test changed.** `test/Reaper_test.res`
injects `~idleStopS` rather than reading `Config`, and `live/LiveWatchdog.res`
overrides it to 2 for its two-second run. That means the acceptance grep is the
whole verification and there is no unit test that would have caught a
half-done edit -- worth knowing, since the failure mode here is exactly the
stale prose this ticket is about: a constant moved and one of six sentences
left behind.

**One site the ticket's own grep would have missed, and one it correctly
excluded.** A wider search over `docs/` still finds `3h`/`10800` in `076` and
`077` and at `map.md:98`, all of them closed-ticket records and history -- left
alone, as instructed. `skills/html-to-markdown/references/benchmark.md:42`
matches `3h`-adjacent patterns only through a `2.8x` timing column, which is why
the ticket's narrower grep is the right one.

**The accepted consequence bites sooner and is unchanged in kind.** A lane whose
`setTtl` or handoff `ttlMinutes` exceeds 45 minutes now outlives the browser
rather than merely outliving it at 3h; the handoff case stays covered by its
screen claim, which is what holds the reap off. No new state, no new knob.

## Accepted consequences, not open questions

- **A lane whose TTL was raised outlives the browser.** `setTtl` and the handoff
  path's `ttlMinutes` can set a lane to wait longer than 45 minutes; `Reaper.decide`
  counts only lanes that hold a *live tab* (`occupiedKnown`), so such a lane does
  not hold the reap off, and a caller who set it will come back to `laneNotFound`.
  That is the pre-existing shape at 3h too — it just bites sooner. The handoff
  case is covered by its screen claim, which does hold the reap off, and that is
  the case the setting exists for.
- **`orphan` and `human` keep no TTL**, unchanged: a human's half-finished login
  is what ticket 018 exists to protect, and neither lane holds the reap off when
  it holds no tab.
- **A fresh Chrome every 45 minutes is the intended cost**, and it is smaller
  than it sounds — the profile survives (`Config.profileDir`), so cookies and
  logins are not lost, only the tabs.
- Making the reap count from *lane-emptiness* instead of from the last call was
  the other candidate and was declined: it behaves identically in the ordinary
  case above, and it would need new state in `Lanes`.

## Not this

Not [the lane TTL](079-a-forgotten-lane-cannot-be-reclaimed.md) — the lane
already lives 30 minutes and this ticket does not move it. Not [the fleet's
ceiling](080-subagent-fleet-exhaustion.md): a browser that stops 45 minutes
after its last call does nothing for the 46 tabs opened inside those 45 minutes.
Not [why the browser costs watts](078-chrome-power-usage.md) — this shortens the
window, it does not shrink the draw.
