---
id: 064
title: A deep state dir silently costs the session its VNC
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
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

## Answer

**Item 1 built: the plan refuses a control socket path the kernel cannot bind.**
Items 2 and the three open decisions are untouched, and are listed below so the
next reader knows what is still owed rather than assuming this ticket settled
them.

- `src/shell/Launch.res:190` — in `nested.plan`, immediately after
  `let ctl = NestedSessions.ctlSocket(port)`, the composed path's length is
  measured and anything past **107** fails with `SocketPathTooLong`, naming the
  limit, the actual length, and the path (`~detail=ctl`). The check lives at the
  call site rather than in `ctlSocket`, which stays a pure path composer —
  `ctlSocket` has exactly one production caller (`Launch.res:181`, verified) and
  the 107 is a property of `sun_path`, not of the string.
- `src/core/Errors.res:33,54` — new code `SocketPathTooLong` /
  `"SOCKET_PATH_TOO_LONG"`, following the `<type>ToString` rule. Adding the
  variant is a compile error until the mapping exists. Nothing else enumerates
  the code strings: `README.md:410` and `Webserve.res:191` mention individual
  codes in prose, not as a table.
- `src/runtime/Node.res:27` — `@val @scope("Buffer") external byteLength:
  string => int = "byteLength"`. No byte-length helper existed in the runtime
  layer.

`npm test`: 141 tests, 141 pass, 0 fail.

### The bug the first pass shipped, and why it is worth reading

The guard was first written as `String.length(ctl) > 107`, which is JavaScript
string length — UTF-16 code units — while the kernel binds a unix socket from
`sun_path`, a byte array. **The two disagree by up to 3x on exactly the paths
this project is aimed at.** Measured:

    $ node -e 'const p = "/home/lyh/" + "文档".repeat(20) + "/passenger/wayvnc-5900.sock";
               console.log(p.length, Buffer.byteLength(p))'
    77 157

`String.length` says 77 and accepts; `sun_path` sees 157 bytes and wayvnc dies
into the pipe nobody reads — the original silent failure, reinstated for CJK
state dirs and only for them. The message also printed that wrong number next
to the word "bytes". The first test could not catch it: its deep path was built
from `String.repeat("deep", 30)`, ASCII, where both measures agree. Fixed in
`7d1aa23`; the guard counts UTF-8 bytes now and the message's word "bytes" is
true.

The second test is the one that would have caught it, and it asserts the split
itself rather than only the refusal: `"文档".repeat(15)` under the default state
dir is **81** by code units and **141** by bytes, and the case asserts
`String.length(deep) + 18 <= 107` *and* that the refusal names the byte length —
so a path over the limit by both measures cannot pass this test and pretend to
be evidence. Confirmed red with the guard reverted to `String.length` (Launch
suite 13/14, the new case failing and the ASCII case still passing), green after.

### What is still owed on this ticket

Item 2 — the session script's stdout/stderr going to a pipe nobody drains — is
untouched, so wayvnc's complaint still lands nowhere. (Note for whoever takes
it: `session.sh:14` already tees the session to `{state}/session.log`, landed
by ticket 066 and asserted at `test/Launch_test.res:141`, so a human *can* read
it — what is missing is that a failed start does not name it.) The two decisions
the ticket poses are likewise open: refuse-or-relocate (the socket could move to
`XDG_RUNTIME_DIR`, and the ticket's argument that relocating *and* checking is
not redundant still stands, since a runtime dir can be overridden), and whether
wayvnc's failure should fail the start at all. This ticket is closed on item 1
only.

**Found, not taken:** the older ASCII case still derives its expected number
with `String.length(deep) + 18` (`test/Launch_test.res:179`). Correct there,
since that path is ASCII — but it reads as code units in a file that now has a
byte measure, and `Node.byteLength` would say what is meant.
