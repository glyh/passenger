# What the stack can do about output size

Measured against the installed versions: cage 0.3.1, wayvnc 0.10.1,
wlvncc (2026-04-29), on Hyprland with a 2880x1800 panel at scale 1.6.

## The starting state

cage's headless output is born **1280x720 at scale 1**, unrelated to any
screen. Chrome reported `devicePixelRatio: 1`. A viewer therefore received
a 1280x720 frame, letterboxed inside its window and resampled onto a HiDPI
panel.

## Findings

**cage implements `wlr-output-management-v1`.** `wlr-randr` lists
`HEADLESS-1` and reconfigures it live:

    wlr-randr --output HEADLESS-1 --custom-mode 2880x1800 --scale 1.6

Chrome follows the change without a restart, and the connected viewer picks
up the new framebuffer size. This is the mechanism the fix uses.

**Client-driven resize does not work here.** wayvnc's automatic resizing is
on by default (`-R` disables it), so the intended design is for the client
to ask. It does not happen:

- **wlvncc never asks.** It logs `Got new framebuffer size` and adapts. It
  has no fullscreen, resize, or scale option -- its whole option set is
  encodings, quality, decorations, cursor.
- **TigerVNC asks and is refused.** Started with `-RemoteResize=1`, it logs
  `CConnection: SetDesktopSize failed: 4` and the output stays put.

So the size has to be set from the compositor side, not requested from the
client side.

**Chrome takes an integer buffer scale.** Setting the output to scale 1.6
gives Chrome `dpr: 2`, not 1.6 -- it renders at 2x and the compositor
downsamples. Crisp, slightly over-rendered, and harmless.

**The viewer's window cannot be measured portably.** No Wayland protocol
exposes another client's geometry, and the IPC that would answer it differs
per desktop. `wl_output` (core, therefore universal) gives the *screen*,
which is exact only when the viewer is fullscreen.

**The cursor needs two flags, not one.** wayvnc omits the pointer from the
frame unless `--render-cursor` is given; with it, a client that also draws
its own cursor shows two. wlvncc's `-n` suppresses the client-side one.

## What was chosen

Size the output from this side, taking the target from the first of:

1. `AGENT_BROWSER_VNC_SIZE` / `AGENT_BROWSER_VNC_SCALE` -- a pinned size.
2. `AGENT_BROWSER_GEOMETRY_CMD` -- a command the user supplies that prints
   `WxH[@scale]`. This is how a tiled window is fitted exactly without the
   tool knowing which compositor is running. See
   `docs/examples/hyprland-fit.sh`.
3. `wayland-info` reading core `wl_output` -- the screen. Exact when the
   viewer is fullscreen, and a large improvement regardless.

Applied on `show`, once the viewer is up, and re-applied on a repeat `show`
so a moved or resized window can be re-fitted.

## Verified

| | before | after |
|---|---|---|
| output | 1280x720 @ 1 | 1422x1730 @ 1.6 (fitted to the tile) |
| Chrome | 1280x720, dpr 1 | 889x1081, dpr 2 |
| border | large, top and bottom | none |
| cursor | not visible | one, drawn server-side |
