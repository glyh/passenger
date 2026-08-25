---
id: 061
title: The nested browser's display platform comes from the host's dotfile
labels: [wayfinder:task]
status: open
assignee:
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
