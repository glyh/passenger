---
id: 076
title: Stop the browser when nobody has used it for hours
labels: [wayfinder:research]
status: open
assignee: lyh (via Claude)
blocked_by: []
---

## Question

Chrome is started on demand and never stopped. That is deliberate -- the warm
logged-in session is the whole product -- but nothing anywhere reaps it, so a
laptop that read one page at 10:00 is still running a full Chrome, a sway
compositor, a wayvnc, and possibly a noVNC viewer at 22:00. On a battery that is
watts spent on nothing, silently, with no window on screen to remind anyone.

`Lanes` already has the shape of the answer for tabs: a per-lane TTL, default
1800s, swept on demand. What it does *not* have is a level above it. `Lanes.sweep`
collects lanes and closes their tabs; the comment at `Lanes.res:399` says outright
that it will not take the daemon down with them. So the terminal state today is a
browser with zero live lanes and zero tabs, running forever.

Proposal: **after some hours with nothing using it, the daemon stops itself, and
takes everything it spawned with it.**

### Why this is not `stop`

`Stop.res` says destructive things a human should own do not get an agent tool,
because "an agent that hits a timeout and helpfully restarts Chrome costs the
owner every login on the machine." That rule is about *judgement* -- an agent
deciding, from one failed call, that the fix is a restart. A clock is not a
judgement, and idle is not a failure. But this ticket has to answer the rule
explicitly rather than around it, because the loss is identical either way: a
reaped Chrome is a lost warm session, and if the reap is wrong the owner pays the
same price.

## To decide

1. **Idle since what.** Wall-clock since launch is wrong -- it kills a session
   someone is using. Candidates: last `script` call, last `Lanes.touch`, last CDP
   activity of any kind. `lanes.touched_at` already exists and is already written
   on use; the max over the table may be the whole measurement.
2. **Three hours, or configurable.** The user's ask names 3h. `Config` is the
   `PASSENGER_*` boundary and `Lanes.defaultTtlS` is a constant beside its type,
   so both patterns exist here. Decide whether 0 means never, as `Lanes.noTtl`
   already does.
3. **What "idle" must never include.** A screen claim (`human` lane, someone
   mid-captcha), a live viewer, an open handoff. 040's refcount already knows;
   `Stop.refusal` already enumerates exactly this set. The reaper should be built
   on the same two questions the refusal asks, not a second opinion about them.
   Open tabs are the interesting case: tabs in `orphan` are a human's and are
   explicitly TTL-exempt, so "no tabs" and "nobody wants this" are not the same
   claim.
4. **Who holds the clock.** Nothing in this process runs on a timer today --
   every sweep is on-demand, at the top of a call. An idle reaper has nobody to
   ride along with, by definition: the case it fires in is the case where no call
   arrives. So this needs either a real `Timers` interval in the serve process
   (and then: what happens when the MCP client disconnects and the server exits?),
   or something outside it. Whether the server process itself should also exit is
   part of this.
5. **What "everything it spawns" is, and whether killing the daemon is enough.**
   `Browser.launch`, `Present`, `Webserve` and `NestedSessions` each `Proc.detach`
   something. Detached means orphaned, so nothing dies by parent death; each has
   to be named. `Stop.run` is the existing inventory of that and should be reused
   rather than re-derived.
6. **How a caller learns it happened.** A lane id that worked an hour ago now
   names nothing. `browserStatus` is the existing place to say so. The failure to
   avoid is a caller getting a bare `pageFor` refusal and reading it as a bug.

## What this must not become

- A restart. Reaping is one direction; the daemon already starts on demand.
- A judgement about failure. Slow, wedged, and idle are three different things,
  and only the third is this ticket's.
- A second opinion about who is using the browser. If `Stop.refusal` would refuse,
  the reaper does not fire.
