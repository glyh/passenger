---
id: 076
title: Stop the browser when nobody has used it for hours
labels: [wayfinder:research]
status: closed
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

## Answer

Yes, build it: the serve process reaps, and lingers only as long as the job
it started needs. The decisions, one per question -- with three facts found
on the way that the question could not have known: `Lanes.occupied` swallows
its own failure, `Webserve.ensure` drops the pid of the one process it
detaches, and `passenger stop` leaves two spawned things alive.

**1. Idle since the newest touch in the registry -- `max(touched_at)`, and
nothing else.**

`lanes.touched_at` is already written on entry *and* return of every
lane-naming call, in the shared sqlite registry that both server processes
write, under the wall clock that already crosses processes there. That makes
it the only idleness fact in the system that survives the two facts of this
deployment: several clients, several processes, one browser. Last CDP
activity was the other candidate and loses on exactly that ground -- the
attach lives in one process for the length of one call, so a CDP-derived
clock cannot see the lane next door, and a clock that cannot see the other
writer kills the other writer's session.

Two things deliberately do *not* count as use:

- **Reads.** `browserStatus` touches nothing, and stays that way. A
  monitoring loop polling status every five minutes would otherwise pin the
  browser forever from a call that never uses it.
- **A human driving the viewer.** Clicks through noVNC reach Chrome and touch
  nothing here. That is fine, because active human use coincides with a
  screen claim or a live viewer -- which are guards (decision 3), never
  idleness signals. The measurement and the guard meet: between them, "nobody
  has used it" is answerable without this side watching input it cannot see.

Accepted blind spot, written down rather than hidden: a single `script` that
runs silent past the whole horizon (possible since 074 removed the cap) ages
out of `touched_at` like any other silence. In practice its own open tabs
shield it -- they are live tabs in a non-orphan lane, so `occupied` is
non-empty and the reaper waits -- and in this process an in-flight call is a
guard outright. What remains is a >3h script holding zero tabs at check time,
which is indistinguishable from idleness to every observer including the
registry, and the remedy is the same as for any long wait: `setTtl` raises
the lane's clock; use refreshes the browser's.

**2. `PASSENGER_IDLE_STOP`, default 10800 -- three hours, as asked -- and
`0` means never.**

This is machine policy (battery versus always-on box), not call semantics, so
it takes the `Config` pattern -- one `int` read with bounds, unset or
unparseable falls back to the default -- rather than a constant beside
`Lanes.defaultTtlS`, which is right for a value no machine would want
different. `0 = never` is not a new spelling: `Lanes.noTtl` already means
exactly that one door over, and importing the convention costs nothing and
answers the question. Bounds 0..2147483647, matching its neighbours.

**3. The guards are `Stop.refusal`'s two questions, plus two the CLI never
needs. The reaper does not get a second opinion.**

It fires only when all of these hold, in this order:

- `dropStaleHumanClaim` first, then `Lanes.screenClaims()` empty. A person
  mid-handoff is a claim; 040 built the refcount and the reaper stands behind
  it, not beside it.
- `Lanes.occupied()` known-empty. **Known** is the finding. `occupied`
  returns `[]` both for "no lanes hold tabs" and for "Chrome would not
  answer" -- the comment there says why, and the why is `stop`'s: a wedged
  browser is the case `stop` exists for, and a check that cannot complete
  must not stand in the way of a human holding `--force`. The reaper's
  polarity is the opposite: a clock that cannot *see* that the lanes are
  empty does not know the browser is idle, and skips the round. So the reaper
  asks the same question through a variant that distinguishes the answer from
  the failure -- it shares `occupied`'s logic and not its exception handling.
  This is the ticket's own line -- idle is not wedged, and only the third
  thing is this ticket's -- applied to the one place the existing inventory
  could have smuggled a wedged kill in as an idle one.
- No call in flight in this process. True of `stop` by construction (it runs
  in a fresh CLI process, nothing of ours can be mid-call), so `refusal`
  never needed it; the reaper lives in the serve process, where a call can be
  mid-flight while the registry looks quiet. One counter around `Session.use`
  is the whole mechanism.

And the orphan question, answered the way `stop` already answered it: orphan
tabs do not block the reap. Not because humans' tabs do not matter, but
because "no tabs" is not a reachable state -- `closeTabs` holds the keeper
back, the keeper lands in `orphan` on the next reconcile, so counting orphan
would mean a horizon that never arrives, which is `occupied`'s own stated
reason for excluding the reserved lanes. What a human actually has at risk
when the reap lands is page state in open tabs, and the logins survive it:
the warm session is the profile on disk, not the tabs. The loss question the
ticket demanded be answered explicitly is therefore: the same loss plain
`passenger stop` already accepts without `--force`, on a 30x longer horizon,
with every guard `stop` has plus two it never needed.

**4. The clock is a `Timers` interval in the serve process -- and the serve
process outlives its client to finish the one job it started, then exits.**

Nothing may reap from *inside* a call, and the state the reap fires in is no
calls at all, so the timer rides with the process that owns the transport.
The lifecycle:

- While a client is connected, today's shape is unchanged: calls sweep; the
  interval rides along and does nothing.
- On transport close: if `PASSENGER_IDLE_STOP=0`, exit immediately -- exactly
  today. Otherwise linger. The interval is *not* unref'd, because after stdio
  closes it is the only handle holding the event loop, and holding it is the
  point. One stderr line says so -- a human who ran `serve` by hand must not
  be left watching a process that will not die and cannot say why.
- Each tick: browser down is nothing left to guard -- `exit(0)`. Browser up
  runs the ordinary sweep on the ordinary clock, which quietly keeps a
  promise the tool already makes and today cannot keep: `openLane` says a
  lane "collects itself after 30 minutes of no calls", and with no call
  arriving, nothing ever collected it. The reap itself closes everything
  anyway; sweeping on the tick is what honors the lanes' own contract in the
  hours before the horizon.
- When the decision says fire: write the tombstone first (decision 6), run
  the shared teardown (decision 5), `exit(0)`.

"After the reap, does the server exit?" -- yes, always. It lingers only while
the consequence of its on-demand start (the browser) outlives it, and there
is no shape in which it becomes a daemon: no reconnect handling (stdio cannot
reconnect; a returning client spawns a fresh process), no teardown on
SIGINT/SIGTERM (a signal means *this process* should go; whether the browser
stays is the policy's business, not the signal's).

The rejected alternative is the detached watchdog -- a `Proc.detach` re-exec
on `--serve-viewer`'s shape, spawned at `Browser.start`, which would fire even
where the client hard-kills the process tree instead of closing stdin. It
loses on its own ticket's terms: it is a resident node process for hours, the
watts this ticket exists to stop, smaller; it must re-derive the teardown
inventory or re-exec to get it; and it captures `PASSENGER_*` at spawn, so
config changed between spawn and fire is config the reaper does not honor.
Where both linger, both fire, and the race is benign -- `Browser.stop` by pid
and record is idempotent, and the second process finds the browser down and
exits. The real bet is that hosts close stdin more often than they kill the
tree; that is checkable in one evening with any client, and the decision
logic lives in one pure function so that switching carriers -- if the field
says otherwise -- is the small part.

**5. "Everything it spawns" is five processes, and `stop`'s inventory names
three.**

`Browser.stop` today reaches Chrome (by `pidsRunning` on our profile dir),
wayvnc and the compositor (by the session record, with the SIGTERM-to-SIGKILL
escalation 024 built). Reading the other detach sites against it found the
two it does not name:

- **The viewer window.** `Present`'s local presenter detaches a host-browser
  in app mode, pid recorded via `recordViewer`. `Browser.stop` does not
  match it -- its `--user-data-dir` points at `viewer-profile`, not the
  nested profile -- and `Stop.run` never calls `dismiss`. On `--force`, the
  window survives, showing a dead socket.
- **The viewer page server.** `Webserve.ensure` detaches a re-exec of this
  same module on `--serve-viewer` -- and throws the pid away (`Some(_) =>
  ...`). Nothing anywhere kills it, so it outlives `stop` today, serving two
  static files until logout.

So the teardown is extracted into one function -- viewer window dismissed,
recorded page-server pid killed, `Browser.stop` -- and both `passenger stop`
and the reaper call it. Reuse rather than re-derive, as the ticket asked;
the reuse is also what *completes* the inventory, because a reaper that
copied `stop` verbatim would have reproduced both orphans at 22:00. The page
server starts recording its pid at `ensure`, symmetric with
`recordViewer`; the kill is by recorded pid, with no `pidsRunning` sweep on
the flag -- a second checkout of this tool on the same machine shares the
flag and not the state dir, and `pkill`-by-name is the exact scar
`Present.dismiss`'s comment is about.

**6. A tombstone in the state dir, read in the two places the surprise
lands -- and no notification.**

The caller experience after a reap is precise, and it is the failure the
ticket named. The lane id that worked at 10:00 is used at 14:01; the next
`script` call starts by *silently starting a fresh Chrome* (`ensureDaemon`),
`Browser.start` drops every registry row, and `housekeep` answers
`no lane <id>` -- LANE_NOT_FOUND on a lane the caller opened itself and
never closed, which reads as a bug, because every other way of losing a lane
is one.

So the reap writes a tombstone to the state dir *before* tearing down --
"stopped idle at T after Ns of no calls" -- and it is read twice:
`browserStatus` reports it as `lastIdleStop`, and `laneNotFound` decorates
its detail with it, at the exact moment the caller hits the surprise. It is
cleared by a human `passenger stop` -- a deliberate act needs no
explanation -- and overwritten by the next reap. It is never cleared by
`Browser.start`, which is what makes it survive the very restart that
erases the lane it explains. Because it lives in the shared state dir, a
reaper in *either* process explains itself to the *other* process's caller
for free -- the same cross-process fact `touched_at` rides on.

No webhook, no desktop notification: `Notify`'s channels assume a human at a
desktop or a webhook set (the map's fog already notes the container that
reaches nobody), the machine owner set the policy that fired, and
announcing a thing the owner configured is noise. The docstrings state the
contract where callers hold ids -- `openLane` and `setTtl` say the browser
itself stops after `PASSENGER_IDLE_STOP` of no calls anywhere -- and the
skill's troubleshooting carries the operating knowledge, per the 032 split.

---

Checked against the ticket's own three refusals: it is not a restart -- the
reap is one-directional, and only a call ever starts Chrome. It is not a
judgement about failure -- slow and wedged never fire it; the wedged case is
the one where it *cannot see* and therefore waits. And it is not a second
opinion about who is using the browser: `Stop.refusal` refusing is
definitionally no-fire, and the two additions (known-empty, no call in
flight) are places the reaper is *more* careful than the human's verb, not
different.

The build is [077](077-build-idle-reap.md).
