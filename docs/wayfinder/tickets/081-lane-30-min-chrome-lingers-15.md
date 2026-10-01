---
id: 081
title: A lane lives 30 minutes, and the browser lingers 15 more
labels: [wayfinder:task]
status: open
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

Acceptance: `grep -rn "10800\|three hours\|3h"` over `src/`, `README.md` and
`skills/` returns nothing (excluding the emitted `.res.mjs`). `map.md:98` is the
decisions-so-far record as it stood at 076 and is history — append the closing
line beside it, do not rewrite it.

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
