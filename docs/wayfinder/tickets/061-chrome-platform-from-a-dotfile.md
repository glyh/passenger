---
id: 061
title: The nested browser's display platform comes from the host's dotfile
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

`Launch.cs` starts Chrome inside a cage session that serves Wayland and
nothing else -- `WLR_BACKENDS=headless`, no DRM master, no X. It never tells
Chrome that. On this machine the browser is a Wayland client anyway, on flags
this repo does not pass:

    --enable-features=UseOzonePlatform,WaylandWindowDecorations
    --ozone-platform-hint=auto

They come from `~/.config/chrome-flags.conf`. The Arch `google-chrome-stable`
wrapper is a shell script that reads that file and splices its contents into
argv, so the developer's personal dotfile is deciding what the nested browser
*is*. Measured on the live session: no Xwayland runs under cage, the tree is
`cage -> chrome` directly, and the flags above are in `/proc/<pid>/cmdline`.

Delete that file, or run on any other machine, and Chrome falls back to X11 --
which inside cage means Xwayland, or, where the closure has no Xwayland, means
a browser that does not start. The tool works here for a reason that is not in
this repository and is not in the closure either.

**This is a bug about correctness before it is one about size.** Chrome is
taken from the host on purpose (its version is fingerprint-visible, ticket
023's reasoning), and that is a decision about *which browser*. It was never a
decision to inherit the host's browser *configuration*: a flags file is
arbitrary, unversioned, invisible to this side, and can carry anything --
`--disable-gpu` in that file would silently undo the hardware GL the nested
session goes to some trouble to keep.

So: `Launch.cs` should say what platform it is launching into, rather than
hoping. The narrow form is `--ozone-platform=wayland` on the argv it already
builds. The wider question this ticket should answer first is whether the
nested Chrome should be insulated from that flags file altogether, and what it
would cost to be -- the wrapper is the thing that reads it, so pointing
`PASSENGER_CHROME` at `/opt/google/chrome/chrome` would bypass both the file
and whatever else the distro's wrapper does for a living.

## What to check before it lands

- **The handoff still hands over a browser.** Ticket 006 took Chrome out of
  fullscreen over CDP so a human gets a toolbar and an address bar rather than
  a bare page. Confirm that survives the platform change, on the X11 path too
  if the fallback is kept.
- **Nothing fingerprint-visible moves.** `screen`, device pixel ratio, and the
  `WaylandWindowDecorations` half of what the dotfile was setting. The measured
  baseline is in the README: `screen: 1280x720`, and WebGL reporting the real
  adapter.
- **Whether X11 stays reachable at all.** If `--ozone-platform=wayland` becomes
  unconditional, a host whose Chrome is too old for ozone has no path left.
  Worth knowing which Chrome versions that covers before closing the door.

## Related

[The bundle carries a Python nothing runs](060-trim-the-closure.md) wants to
drop Xwayland and the gtk+3 that rides in behind it, and cannot until this is
settled: today Xwayland is what catches a Chrome that fell back to X11. This
ticket is the correctness half, 060 the size half, and this one comes first.

## Answer

Both halves, and they are separate mechanisms.

**The platform is now stated.** `Launch.NestedBackend` splices
`--ozone-platform=wayland` into the argv it is handed, after `argv[0]` so the
generated script still reads as "this browser, these flags". Unconditional, and
only in that backend: there is no X inside the session to fall back to, so
nothing reachable is being closed off, and `--visible` still leaves the host's
own desktop to decide. The flag has been accepted since ozone shipped, and a
Chrome old enough not to take it could never have run in here anyway -- which
answers the third check: no X11 path is being kept, because there was never one
that worked without Xwayland.

**The flags file is out.** The distribution's `google-chrome-stable` is a shell
wrapper that splices `$XDG_CONFIG_HOME/chrome-flags.conf` into argv, so the
session script now points Chrome at its own `$XDG_CONFIG_HOME`.

Not an empty one. A blank config directory would have insulated Chrome from far
more than one file -- `$XDG_CONFIG_HOME` is also where fontconfig and GTK keep
theirs, and inheriting the host's fonts is the argument this repo makes against
Docker. So it is a symlink farm: every entry of the real config directory
linked into `{state}/xdg-config`, rebuilt per start, minus `chrome-flags.conf`.
Links rather than copies, so anything that writes still writes to the real file.
Bypassing the wrapper instead (pointing `PASSENGER_CHROME` at
`/opt/google/chrome/chrome`) was rejected: it drops one known file at the cost
of whatever else an unknown distribution's wrapper does for a living.

Measured on a fresh session, and `/proc/<pid>/cmdline` now reads:

    /opt/google/chrome/chrome --ozone-platform=wayland --remote-debugging-port=9222 ...

with none of `--enable-features=UseOzonePlatform,WaylandWindowDecorations`,
`--ozone-platform-hint=auto` or `--touch-events` in it. The farm carried 101
entries; `chrome-flags.conf` was not one.

**What moved: nothing measurable, which is the good outcome.** The flag worth
suspecting was `--touch-events`, and it turns out to have been doing nothing
visible on this Chrome -- measured on both sides, `navigator.maxTouchPoints` is
0 and `'ontouchstart' in window` is true with the flag and without it (Chrome
exposes the handlers on desktop regardless). So this is a correctness fix rather
than a fingerprint fix: the point is that the file is no longer an input, not
that a particular flag in it was hurting. It could have said `--disable-gpu`
tomorrow. The rest of the README's baseline is unchanged -- `screen: 1280x720`,
`devicePixelRatio: 1`, WebGL still
`ANGLE (Intel, Mesa Intel(R) Graphics (LNL), OpenGL ES 3.2)`, so hardware GL
survived the explicit platform. Window decorations survived too, without the
`WaylandWindowDecorations` feature the dotfile was passing: Chrome draws them by
default now. Ticket 006's check holds -- `outerHeight` 740 against
`innerHeight` 633 is 107px of tab strip and toolbar, and the window is not
fullscreen.

The log carries one new line,
`'--ozone-platform=wayland' is not compatible with Vulkan`, and it is noise: the
same warning appeared before this change (the dotfile's hint resolved to wayland
too), and the renderer string proves the GPU is still in play.

**It did not fix [067](067-ime-segfaults-chrome.md).** Retried with
`PASSENGER_IME=fcitx5` on controlled flags, Chrome segfaulted 0.2s after
announcing CDP -- the same signature 067 records. That trial was also
contaminated (another Passenger server on the machine restarted the daemon on
port 9222 underneath it, from an older build), so it is one datapoint rather
than a clean run; it is enough to say the flags were not the cause. 067 stays
open and loses its "wait for 061" note.

[060](060-trim-the-closure.md) is now unblocked on this side: nothing falls back
to X11 any more, so Xwayland is no longer catching anything.
