---
id: 060
title: The bundle carries a Python nothing runs
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

`nix bundle --bundler github:NixOS/bundlers#toArx .#packages.x86_64-linux.default`
produces one 302 MB executable that speaks MCP on a machine with no nix — the
whole runtime side travels, Chrome deliberately does not, and the compositor
still starts where there is no GPU (measured: vulkan fails, wlroots falls back
to the pixman renderer, cage runs its child, exit 0). That is the artifact this
ticket is about; it is not what is in question.

The closure behind it is 896 MiB across 258 paths, and its largest single entry
is a Python interpreter:

     135.4 MiB  python3-3.14.7
      85.7 MiB  nodejs-slim-24.19.0   (+ npm 12.1 MiB, + corepack)
      78.3 MiB  dotnet-runtime-10.0.10
      41.6 MiB  gtk+3-3.24.52
      39.5 MiB  icu4c-78.3
      36.1 MiB  passenger-0.1.0       <- the build itself
      33.8 MiB  ffmpeg-9.0-lib
      33.4 MiB  glibc-2.42-67

**Nothing in this project has run Python since ticket 023.** It arrives through
a shebang, on a script for analysing mouse buttons:

    Passenger.Mcp -> cage -> wlroots -> libinput-1.31.3-dev
      -> libinput-1.31.3-bin
      -> libexec/libinput/libinput-analyze-buttons   #!/nix/store/...-python3-3.14.7-env

`wlroots` propagates `libinput-dev`, `libinput-dev` propagates `libinput-bin`,
and one interpreter line in a tool this codebase will never invoke makes CPython
a runtime dependency of an MCP server. `Launch.cs` starts cage with
`WLR_LIBINPUT_NO_DEVICES=1`, so there are not even input devices for it to
analyse.

The question is what removes it without lying to the closure scanner:
`removeReferencesTo` on the wrapper, a `libinput` override that drops the `bin`
output, or overriding `wlroots`'s propagation. Whichever it is, it has to be
checked against a real handoff -- cage starting, wayvnc serving, a viewer
attaching -- and not only against `nix build` succeeding.

## Two neighbours, measured but not settled here

**Node is load-bearing; `npm` and `corepack` are not.** Playwright's wire
protocol is driven by a Node process, and `postFixup` substitutes nixpkgs' node
for Patchright's bundled one. It reaches for `pkgs.nodejs`, which carries npm
and corepack; `pkgs.nodejs-slim` is the same interpreter without them. The
interpreter itself, 85.7 MiB, is not negotiable.

**gtk+3 is Xwayland's, and Xwayland is load-bearing for the wrong reason:**

    Passenger.Mcp -> cage -> xwayland-24.1.13 -> libdecor-0.2.5 -> gtk+3

Nothing here links gtk. It arrives because libdecor draws client-side window
decorations, which Xwayland wants. Dropping Xwayland from cage and wlroots
would drop both -- but only if Chrome is a Wayland client inside the cage, and
measuring the live session turned up something worse than a no.

It *is* a Wayland client. No Xwayland runs under cage (the one on this machine
is the host compositor's, started days earlier under a different parent), and
Chrome's argv carries:

    --enable-features=UseOzonePlatform,WaylandWindowDecorations
    --ozone-platform-hint=auto

**Nothing in this repo passes those.** They come from
`~/.config/chrome-flags.conf`, a personal dotfile of the developer's, which the
Arch `google-chrome-stable` wrapper script reads and splices into argv. So the
nested browser takes the Wayland path here by coincidence, and on any host
without that file -- which is every host the bundle is for -- Chrome would
default to X11 and need the Xwayland inside cage to start at all.

That makes this a portability bug that predates the bundle and was only visible
through it. The fix points the same way as the trim: `Launch.cs` already knows
it is launching Chrome into a cage Wayland session, so it should pass
`--ozone-platform=wayland` itself rather than inherit the question from whoever
happens to own the machine. Once it does, Xwayland and gtk+3 can leave together. That half is now its own
ticket: [The nested browser's display platform comes from the host's
dotfile](061-chrome-platform-from-a-dotfile.md), which has to close before the
Xwayland trim can be attempted. **It has: 061 passes `--ozone-platform=wayland`
unconditionally in the nested backend, so nothing falls back to X11 and nothing
in the session needs Xwayland to catch it.** The trim is unblocked.

Two things to check before that lands, since it changes what the browser is
rather than what ships beside it: that the handoff window still behaves (ticket
006 took Chrome out of fullscreen so a human gets a real toolbar), and that
nothing fingerprint-visible moves with the platform swap -- `screen`, device
pixel ratio, and the `WaylandWindowDecorations` half of the flag the dotfile
was also setting.

## Why this is worth doing at all

Not the megabytes on their own. The tool inherits the host on purpose -- its
fonts, its GPU, its IP -- and a closure that also inherits a Python for a mouse
utility is the same failure in the other direction: things arriving because
nothing stopped them, rather than because someone asked. The bundle is the
first artifact where that cost is visible to whoever downloads it.

## Answer

All three, and the interesting part is that only one of them changes what gets
built. **896 MiB across 268 paths -> 658 MiB across 216**, and the `toArx`
bundle the ticket opens with, **302 MB -> 222 MB**.

**The Python is a propagation, not a dependency.** libinput splits into
`out`/`bin`/`dev`, and nixpkgs' multiple-outputs hook has `dev` propagate `bin`
so that a package building against a library also gets its tools on PATH. So
holding libinput's *headers* -- which wlroots does, and propagates in turn --
makes eleven Python analysis scripts a runtime reference, and their shebang
drags CPython, setuptools, pyyaml, pyudev and libevdev in behind them.

The knob for it is `propagatedBuildOutputs`, which names the outputs `dev`
passes on; setting it to `[ "out" ]` on an overridden libinput ends the chain.
The tools are still built and still work for anyone who installs libinput --
what stops is a header consumer inheriting them, and nothing in this closure
runs a libinput binary at build time. Worth recording that the obvious version
of this does not work and looks like it does: editing
`$dev/nix-support/propagated-build-inputs` from `postFixup` succeeds, and is
then overwritten, because `_multioutPropagateDev` runs *after* `postFixup`
inside the same `runHook`. The build passes, the closure does not move, and
nothing says why.

**Xwayland is compiled out**, now that [061](061-chrome-platform-from-a-dotfile.md)
has closed: `enableXWayland = false` through `sway` to `sway-unwrapped` to
wlroots. gtk+3 and libdecor leave with it. This is the one trim that changes the
artifact rather than the reference graph, and it is only safe because nothing
falls back to X11 any more.

**Node is `nodejs-slim`**, losing npm and corepack. What runs is Playwright's
driver over a pipe; it installs nothing.

Verified against a real handoff on the built closure, not just a green
`nix build` -- server on its own state dir and ports (`PASSENGER_STATE`,
`PASSENGER_PORT`, `PASSENGER_VNC_PORT`, `PASSENGER_NOVNC_PORT`, so the
developer's own server was never disturbed):

- sway came up headless, Chrome ran inside it, `https://example.com` loaded and
  read back through `script`;
- wayvnc bound its port and answered a websocket upgrade with `RFB 003.008`;
- the noVNC viewer page served, 7001 bytes of it;
- the two checks this ticket asked for: `outerHeight` 740 against `innerHeight`
  633 is 107px of tab strip and toolbar, so ticket 006's un-fullscreening
  survives; and nothing fingerprint-visible moved -- `screen: 1280x720`,
  `devicePixelRatio: 1`, WebGL still
  `ANGLE (Intel, Mesa Intel(R) Graphics (LNL), OpenGL ES 3.2)`. The
  `WaylandWindowDecorations` half of the question answered itself under 061:
  Chrome draws its decorations without being asked.

The bundle runs (`--help` from the 222 MB executable, exit 0).

What is left at the top of the closure is load-bearing or nearly so:
nodejs-slim 85.7 MiB, dotnet-runtime 78.3, icu4c 39.5, the build itself 36.1,
ffmpeg-lib 33.8 (wayvnc's, for encoding the framebuffer), glibc 33.4.
