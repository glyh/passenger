---
id: 086
title: A live session can name a VNC endpoint that nothing serves
labels: [wayfinder:task]
status: open
assignee: lyh (via Claude)
blocked_by: []
---

## Question

Call `showBrowser` and everything reports success. The viewer page is served,
it loads, and it sits on **"reconnecting"** forever. The human sees nothing.

`browserStatus` agrees with itself and with nothing else:

    {"daemon":"up","launch":"nested","presenter":"local","onScreen":"False",
     "profile":"/home/lyh/.local/share/passenger/chrome-profile",
     "session":"live","vnc":"127.0.0.1:5900",
     "tabs":"34 open, 1 orphan","wedged":"none","lastIdleStop":"none",
     "screenClaims":"1"}

Read against the machine, at the same moment:

| Claim | Fact |
| --- | --- |
| `vnc: 127.0.0.1:5900` | `ss -ltnp \| grep :5900` → nothing. `ss -lxp \| grep -i vnc` → nothing |
| `session: live` | `pgrep -a -f wayvnc` → no such process |
| `onScreen: False`, `screenClaims: 1` | the status object contradicts itself in two adjacent fields |
| — | `pgrep -a -f 'cage\|sway'` → `sway -c /home/lyh/.local/share/passenger/sway.conf` (787495), `swaybg`. **The compositor is up** |

So the session is genuinely live and the compositor genuinely came up, and the
one thing a human needs is absent — while the two calls a human's agent makes
both say it is there.

### This is 064's disease by a different route

[064](064-wayvnc-socket-path-too-long.md) is closed, and its closing note drew
the general shape:

> a session that reports itself live while the thing a human is eventually
> going to need is missing -- and it is the handoff that pays, at the exact
> moment somebody is being asked to solve a captcha

That is not a description of the path-length bug. It is a description of *any*
way `wayvnc` can fail to come up. 064 fixed **one cause** and, by its own
reasoning, should have fixed **the silence**; this recurrence says the silence
survived. Nothing about this machine's configuration is near 064's limit:

- `PASSENGER_STATE` is **not set** on the session. The state dir is the default,
  and `{state}/wayvnc-5900.sock` is **49 bytes** against a 107-byte ceiling.
- `wayvnc` is installed: `/usr/bin/wayvnc`.
- The compositor started, and Chrome started inside it.

What is left is the failure 064 named but did not close: `wayvnc` can exit
without coming up, and the only trace goes to a pipe nobody drains.

### The same mistake 058 fixed, one port over

[058](058-stale-webserve-squats-the-port.md)'s Answer is the precedent, and it
is exact: *"Identity, not liveness."* For the viewer port, `Ensure` was changed
to fetch `/` and ask whether what came back is ours, because `Listening(port)`
was a claim about intent rather than about the world.

`browserStatus` reports `vnc: 127.0.0.1:5900` the old way. It is a **plan** —
the address the session intends to serve VNC on — presented in a field that
reads like an observation, next to `daemon` and `session` which really are
observations. A caller cannot tell the two apart, and the field is wrong in the
only case where it matters.

`showBrowser` compounds it: it returned

    opened google-chrome-stable on http://127.0.0.1:6080/?ws=127.0.0.1:5900, scale 1.601562

for a handoff that could not work. The page was served, so the viewer half of
that sentence is true; the half the human depends on — the `ws=` target — was
never checked.

## What to decide

- **Whether `showBrowser` should refuse when the far end is dead.** The
  handoff is the one path whose entire value is that a human can see something.
  Handing back a URL that cannot connect is worse than an error: it spends the
  human's attention, and it does so at the moment they were asked to help.
  The viewer is already the thing that reads a URL; asking it one question
  before returning is the same move `Ensure` already makes.
- **What `browserStatus` should do about `vnc`.** Either the field becomes an
  observation with a tri-state (serving / planned-but-dead / none), or it stops
  being a field. A bare address that is right most of the time is the shape
  that costs the most when it is wrong.
- **Whether `wayvnc`'s stderr is drained anywhere.** 064 wrote that the only
  evidence was a line on an undrained pipe. If that is still true, then this
  ticket cannot be closed by a guard alone: the reason `wayvnc` died is not
  recoverable from the machine, and the next occurrence will cost the same
  hour. Draining it is what turns "VNC is missing" into "VNC is missing
  because X".
- **Whether `screenClaims` and `onScreen` belong in one object.** They can
  disagree, and they did. A single status whose two fields contradict each
  other teaches a reader to trust neither.

## Repro

With a live session whose VNC is absent (the state observed here — `session:
live`, nothing on 5900):

    showBrowser  -> returns the viewer URL and a ws= target
    browserStatus -> vnc: 127.0.0.1:5900, session: live
    ss -ltnp | grep :5900      -> empty
    pgrep -a wayvnc            -> empty
    human opens the viewer     -> "reconnecting", indefinitely

No failure is reported at any step.

## How it was found

2026-10-03, on this machine, from an agent that had been asked to get a human
past a login wall. 大众点评 had started answering every search page with
`account.dianping.com/pclogin`, and a QR scan was the only way through. The
agent opened a lane, landed on the login page, called `showBrowser`, and told
the human to scan.

The human could not see anything, and said so. Everything up to that point had
reported success — which is the whole cost of this bug: the agent kept
reporting a working handoff, the human kept looking at a page that said
"reconnecting", and the captcha that needed solving was never shown to anyone.
Two agents had already failed to answer the question the login was for, and
this was the escalation path.

### Aside, for whoever reads this next

`map.md` still says Chrome runs inside its own **`cage`** compositor.
[063](063-sway-instead-of-cage.md) moved that to `sway`, and the process table
agrees with 063. Worth correcting while this area is being read, since this
ticket is about the link between the compositor and the thing serving it, and
the map names the wrong compositor.
