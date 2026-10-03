---
id: 087
title: The session takes whatever wayvnc is on PATH
labels: [wayfinder:task]
status: open
assignee:
blocked_by: []
---

## Question

The generated session script runs bare `wayvnc`, so which wayvnc serves the
session -- and therefore whether the handoff works at all -- is decided by the
PATH of whichever process spawned the server. On this machine that decided it
wrongly, and the handoff was dead for two sessions before anyone understood
why.

Found while closing [086](086-live-session-with-no-vnc-behind-it.md), which
fixed the silence around a missing VNC. The silence was real; so was the
missing VNC, and this is the cause of it.

### What was measured

Two wayvnc builds are on this machine. A hand-rolled WebSocket+RFB client was
pointed at each, with nothing else varied:

    /usr/bin/wayvnc 0.10.2   (Arch, neatvnc 1.0.2, nettle 4)
        client connects -> SIGSEGV, exit 139, segfault at 0 ip 0

    nix wayvnc 0.10.1        (flake, neatvnc 1.0.1)
        client connects -> RFB version, security type 1, ServerInit 800x450
                           "WayVNC", framebuffer updates, process alive

`coredumpctl` agrees, twice: `wayvnc[787512]` at 18:17 and `wayvnc[854803]` at
20:15, each within a second of a viewer connecting. The crash is in
`libneatvnc` and happens **during the WebSocket upgrade** -- before a single
RFB byte, so a bare HTTP upgrade is enough and no VNC client is required.

Upstream knows: [neatvnc #177](https://github.com/any1/neatvnc/issues/177)
(closed) -- `ws_handshake()` passes the pre-nettle-4 argument list, so the
digest size lands in the `enum crypto_hash_type` parameter and a NULL `update`
pointer is called. The fix, `8e0d2260`, is on master only: `v1.0.2` still
declares the 4-argument `crypto_hash_many` and does not contain the fix, so the
released 1.0.x line is nettle-3 code and **Arch's package is a nettle-4 build
of it**. That is why the flake's 0.10.1 works and the distribution's 0.10.2
does not, and it is not something this repo can patch.

### Why the session got that one

    PATH=/home/lyh/.local/bin:/nix/var/nix/profiles/default/bin:...:/usr/bin

Read out of the live `session.sh`, and there is no nix *store* wayvnc on it, so
bare `wayvnc` falls through to the Arch package. The dev shell's PATH has the
store one first. A server launched by a client that is not in the dev shell
does not -- which is [083](083-one-file-with-bun.md) arriving by a route the
ticket did not name: shipping one file and stopping needing nix also stops the
session inheriting the flake's tools, and the first of them to matter was this
one.

`Launch.nested.available` gates on `which("wayvnc")->Option.isSome`, which is
the same PATH question asked at plan time and answers yes for a build that
segfaults on any connection.

## What to decide

- **Pin it, or check it?** `Config.chromeBin` already shows the shape for the
  analogous problem (`PASSENGER_CHROME`, an absolute path). A `PASSENGER_WAYVNC`
  defaulting to the flake's is the same move; the flake already puts wayvnc in
  the package closure, so the path exists -- it is only `nix run` that puts it
  on PATH, and 083's whole point is not needing `nix run`.
- **Should a version be refused?** 0.10.2 is not always broken -- it is broken
  as Arch builds it, against nettle 4 with an unfixed handshake. A version
  check is cheap to state and is a policy about someone else's bug, which this
  project has generally declined. The alternative is to let it start and let
  086's `VNC_NOT_SERVING` say so, which is honest but late: the human is
  already being asked to help by then.
- **Should this fail the start?** 086 left it open and this makes it sharper.
  Today a session with a dead VNC comes up looking healthy and reads pages
  fine; only being looked at is broken. Whether that is a failure is a
  judgement about what the tool is for, and 086's error now reports it either
  way.
- **The workaround on this machine, recorded so it is not mistaken for the
  fix:** a symlink at `~/.local/bin/wayvnc` (first on the session's PATH)
  pointing at the flake's 0.10.1, an indirect GC root under
  `~/.local/share/passenger/pins/` so `nix-collect-garbage` cannot take it, and
  `session.env`'s `vnc_pid` repaired by hand to the restarted server so
  teardown still names it.
