---
id: 086
title: A live session can name a VNC endpoint that nothing serves
labels: [wayfinder:task]
status: closed
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

## Answer

All four decisions were taken as the ticket argued them, and the fourth was
free: `onScreen` had no reader outside `Main.res` -- no test, no skill, no
live check -- so renaming it cost nothing.

- **`showBrowser` refuses when the far end is dead.** `Present.requireVnc`
  (`src/shell/Present.res`, beside `endpoint`) probes the endpoint the way a
  viewer would -- `NestedSessions.isListening` on the live session's host and
  port -- and raises a new `VNC_NOT_SERVING` naming the endpoint, the recorded
  `wayvnc` pid, the core file when there is one, and `session.log`. One call
  behind all three presenters, including `none`'s advice line, whose whole
  reply is an address and would otherwise point a noVNC at a dead port.
- **`browserStatus`'s `vnc` is an observation.** `$host:$port` -- a plan that
  is right until the moment it matters -- became `serving host:port` / `dead`
  / `none`, the last for a configuration with no nested session at all.
- **`onScreen` became `viewer`, reporting `up`/`down`.** The old name read as
  "somebody is looking at the screen" and so contradicted `screenClaims`
  beside it; both fields were true in the incident (window gone, claim
  lingering) and read as one false. `viewer` is what is measured.
- **wayvnc's stderr was already drained** -- ticket 066 sends the session to
  `{state}/session.log`, and 064's closing note had it as still owed. Draining
  it was never going to be enough here: **a segfault writes no stderr**, so the
  log was as empty after the crash as before it. What names the death is the
  core systemd-coredump kept, matched on the pid -- `coredumpOf("wayvnc",
  session.vncPid)`, over `core.<exe>.<uid>.<bootid>.<pid>.<timestamp>`. Matching
  the program alone was the first version and it is wrong on the ordinary
  machine that has left an older core around: it blames this death on that
  one, which is an invented cause, the same lie as no cause at all.

`npm test`: **154 tests, 154 pass**. `test/Present_test.res` is six new cases
against a temp state dir with liveness stubbed (the `Sessions_test` pattern):
`none` / `dead` / `serving`, the refusal's code and its pid-and-log detail, a
core that matches, a core that does not, and no core at all.

### The cause, found the same evening -- and it is not this ticket's to fix

The silence was real and this closes it, but the reason `wayvnc` was missing
turned out to be findable after all, and worth recording because it decides
what happens next.

**The session was running a wayvnc that segfaults on every WebSocket
connection.** Two builds are on this machine: `/usr/bin/wayvnc` 0.10.2 (Arch,
neatvnc 1.0.2, linked against nettle 4) and the flake's `wayvnc` 0.10.1
(neatvnc 1.0.1). Measured, with a hand-rolled WebSocket+RFB client as the only
variable:

    /usr/bin/wayvnc 0.10.2   client connects -> SIGSEGV, exit 139, segfault at 0
    nix wayvnc 0.10.1        client connects -> handshake, ServerInit, frames, alive

`coredumpctl` agrees: `wayvnc[787512]: segfault at 0 ip 0000000000000000`, and
a second one at 20:15 for the next session's `wayvnc`, each within a second of
a viewer connecting. The viewer's "reconnecting" was not a viewer problem and
not a session problem: the thing it was connecting to died on connection.

**Why the wrong one.** The generated session script calls bare `wayvnc`, so it
resolves on the PATH of whatever spawned the server. Read out of the live
process, that PATH begins
`/home/lyh/.local/bin:/nix/var/nix/profiles/default/bin:...` -- no nix *store*
wayvnc on it, so the name falls through to `/usr/bin`, the Arch package. The
dev shell's PATH has the store one first; a server launched as a standalone
compiled binary, by a client that is not in the dev shell, does not. The
session script is therefore reading a variable nobody set for it.

**Upstream.** It is a known bug, and it is already fixed -- but not in any
release. [neatvnc #177](https://github.com/any1/neatvnc/issues/177) (closed)
describes it exactly: `ws_handshake()` calls `crypto_hash_many()` with the
pre-nettle-4 argument list, so the digest size lands in the
`enum crypto_hash_type` parameter, `crypto_hash_new()` matches no case, and
the NULL `update` pointer is called. Its fix, `8e0d2260` "stream: ws:
handshake: Fix crypto_hash_many argument mixup", is on master only:
`v1.0.2`'s `include/crypto.h` still declares the 4-argument form and
`v1.0.2...master` contains the fix, so **the released 1.0.x line is nettle-3
code**, and Arch's package is a nettle-4 build of it. Nothing in this repo can
fix that, and no guard in this repo can prevent it: the crash happens *as the
viewer connects*, so a check before the handoff can only report the state it
found a moment earlier.

### What is still owed

- **The session still resolves `wayvnc` from PATH, and that is the defect
  under this one.** [087](087-the-session-takes-whatever-wayvnc-is-on-path.md)
  carries it: a pinned path, or a version check at plan time, so a machine's
  package manager cannot decide whether the handoff works. The local
  workaround applied the same evening is a shim at `~/.local/bin/wayvnc`
  (first on the session's PATH) pointing at the flake's 0.10.1, plus an
  indirect GC root so `nix-collect-garbage` cannot take it; the record's
  `vnc_pid` was repaired by hand to the restarted server so teardown still
  names it. That is a machine, not a fix.
- **Nothing supervises wayvnc.** The ticket asked whether a failed start
  should fail the session; it still does not, and now there is a second shape
  -- a *running* server that dies mid-handoff -- which a start-time check
  cannot cover at all.
- **The 064 item 2 note is now wrong** and was corrected above rather than
  left standing: `session.log` landed in 066, and this crash proves draining
  it is not the general answer.
