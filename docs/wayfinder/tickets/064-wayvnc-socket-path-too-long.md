---
id: 064
title: A deep state dir silently costs the session its VNC
labels: [wayfinder:task]
status: open
assignee:
blocked_by: []
---

## Question

Point `PASSENGER_STATE` at a directory deep enough and the session comes up with
a browser, a session record, a live compositor -- and no VNC at all. Nothing
says so. The only evidence is a line wayvnc wrote to a pipe nobody drains:

    ERROR: ../src/ctl-server.c: 868: Failed to create unix socket: File name too long

`Sessions.CtlSocket` puts the control socket in the state dir
(`{state}/wayvnc-{port}.sock`), and a unix socket path is capped at
`sizeof(sun_path)` -- 108 bytes on Linux, 107 usable. The default leaves plenty
of room:

    /home/lyh/.local/share/passenger/wayvnc-5900.sock     49 bytes
    headroom for PASSENGER_STATE before it breaks         89 bytes

89 bytes is not a lot for a path chosen by whoever sets the variable. It was
found by setting it to a scratch directory an agent had been handed, which
happened to be 92 bytes deep.

**The bug is the silence, not the limit.** This project keeps refusing to let a
tool report health it has not got: the record is written from inside the session
so it names what really came up; `Alive` is keyed on Chrome because a compositor
outliving it is the stale state; `ReapStale` exists because a stale wayvnc
serving an empty compositor is a black screen with everything claiming to be
fine. This is that same shape one layer down -- a session that reports itself
live while the thing a human is eventually going to need is missing -- and it is
the handoff that pays, at the exact moment somebody is being asked to solve a
captcha.

Two things are wrong at once, and they are separable:

1. **A path that cannot work is accepted.** `Launch.NestedBackend.Plan` composes
   the socket path and could measure it. 107 bytes is a fixed, knowable limit;
   refusing at plan time with a message naming the limit and the length is
   cheaper than any diagnosis after the fact.
2. **The session script's output goes nowhere.** `Browser.Spawn` redirects the
   compositor's stdout and stderr and only drains them when `detach` is set, so
   wayvnc's complaint lands in a pipe that is never read -- and a pipe that
   nobody reads is also a pipe that can fill and block. Everything the nested
   session says about itself is discarded this way, not just this line.

## To decide

- **Refuse, or relocate?** The socket does not have to live in the state dir.
  `XDG_RUNTIME_DIR` is where a control socket conventionally belongs, is short
  by construction, and is already used by everything else in the nested session.
  That makes the failure impossible rather than diagnosable -- but it moves a
  file that `Forget` deletes and the record names, so the two have to move
  together. Relocating and *also* checking is not redundant: a runtime dir can be
  overridden too.
- **What the session says about itself.** If 2 is fixed by draining the pipes
  somewhere readable, that is a log, and this project has never had one. The
  narrow version is to keep the last few lines and put them in the error when a
  session fails to come up, which needs no log file and no policy about where it
  lives.
- **Whether wayvnc's failure should fail the start at all.** Today Chrome comes
  up and the tool works for everything except being looked at. That may be the
  right trade -- reading pages does not need VNC -- but then `browserStatus`
  should say the screen is unavailable, rather than the first `showBrowser` of
  the day discovering it.
