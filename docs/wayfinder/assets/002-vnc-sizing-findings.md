# What the stack can do about output size

Measured against the installed versions: cage 0.3.1, wayvnc 0.10.1, wlvncc
(2026-04-29), TigerVNC 1.16.2, noVNC 1.7.0, on Hyprland with a 2880x1800 panel
at scale 1.6.

## The starting state

cage's headless output is born **1280x720 at scale 1**, unrelated to any
screen. Chrome reported `devicePixelRatio: 1`. A viewer therefore received a
1280x720 frame, letterboxed inside its window and resampled onto a HiDPI panel.

## Findings

**cage implements `wlr-output-management-v1`.** `wlr-randr` lists `HEADLESS-1`
and reconfigures it live:

    wlr-randr --output HEADLESS-1 --custom-mode 2880x1800 --scale 1.6

Chrome follows the change without a restart, within a second, in both
directions. Its JS `innerWidth` goes stale and keeps reporting the old size,
but the layout and the frame are correct -- `grim` on the nested output shows
Chrome filling it edge to edge.

**wlvncc cannot be sized from this side, at all.** Two behaviours combine:

- It **stretches** the frame to fill its window rather than letterboxing it.
  Measured: framebuffer 1400x1700 in an 889x1081 window matched a plain
  stretch with RMSE 3.4%, against 37% for aspect-preserving letterbox.
- It **freezes the aspect ratio it connected with**. Resize the output under a
  connected wlvncc and the new frame is squeezed into the old shape with black
  filling the rest: connect at 1280x720, resize to 1422x1730, and the window
  shows a 1422x**801** band -- 801/1422 being 720/1280.

So with wlvncc the size has to be right *before* it connects. Which turned out
to be unwinnable:

**wayvnc advertises a resize to clients some time after `wlr-randr` returns.**
A client connecting inside that gap negotiates the *old* size and, being
wlvncc, keeps it forever. This is what made the fault intermittent: hand-tested
sequences with a 1--3s pause between resize and connect looked perfect, while
the code -- which connected ~0.5s after resizing -- produced a squashed
picture. Two separate reproductions showed the band matching the pre-resize
framebuffer exactly (0.625 = 1800/2880, 0.599 = 1500/900). There is no signal
to wait on.

**Client-driven resize works. The `SetDesktopSize failed: 4` was a red
herring.** TigerVNC logs the failure *and the resize happens anyway*:

    DesktopWindow: Requesting framebuffer resize from 1200x1200 to 1422x1730
    CConnection: SetDesktopSize failed: 4
    Viewport:    Resizing framebuffer from 1200x1200 to 1422x1730   <- it worked

Started against a deliberately wrong 1280x720 output, TigerVNC drove it to
1422x1730 -- its own window in physical pixels -- unaided. This retires
[Why wayvnc refuses the client's resize request](../tickets/003-client-driven-resize.md).

**noVNC drives it too, and costs almost nothing.** A headless browser at
viewport 1000x1400 produced a 1000x1400 framebuffer; at 900x1500, 900x1500.
Against `wayvnc --websocket` it needs no websockify at all -- 1.8 MB of static
JavaScript, served by this tool's own Python.

**What each candidate costs, and whether it resizes:**

| client | drives the framebuffer | closure |
|---|---|---|
| noVNC static + `wayvnc --websocket` | yes | **1.4 MiB** |
| noVNC package (with websockify) | yes | 471 MiB (443 of it numpy) |
| TigerVNC `vncviewer` | yes | 1.2 GiB (fltk pulls gcc-wrapper, pipewire) |
| virt-viewer / gtk-vnc | **no** -- no `SetDesktopSize` in libgtk-vnc | 972 MiB |
| remmina | unverified | 1.1 GiB |
| wlvncc | **no** -- stretches, freezes aspect at connect | 328 MiB |

**noVNC knows nothing about HiDPI.** Left alone it asks for a framebuffer the
size of its window in *CSS* pixels and paints one framebuffer pixel per CSS
pixel, so on a scaled screen the remote browser arrives upscaled. Overriding
`_screenSize` to ask in device pixels and `_updateScale` to lay the canvas out
in CSS pixels gives 1 framebuffer pixel per device pixel: measured window
889x1081 CSS, canvas backing store 1423x1730, displayed at 889x1081.

Going through noVNC's own `autoscale` rather than a CSS transform is load
bearing: pointer coordinates are divided by the scale noVNC knows about
(`absX = x / scale`), so a CSS transform it could not see would land every
click in the wrong place.

`--force-device-scale-factor=1` looks like it would avoid the overrides and
does the opposite: under fractional scaling Chrome maps CSS pixels onto
*logical* pixels, so the framebuffer dropped to 889x1081 and the compositor
upscaled it.

**Chrome takes an integer buffer scale.** Setting the output to scale 1.6
gives Chrome `dpr: 2`, not 1.6 -- it renders at 2x and the compositor
downsamples. Crisp, slightly over-rendered, and harmless.

**Setting the scale does not disturb a connected viewer.** Only the mode does.
Watched through 1.6 -> 2 -> 1.6 with a client connected: the framebuffer size
never changed and the picture stayed whole.

**cage does expose the input protocols.** `zwp_virtual_keyboard_manager_v1` and
`zwlr_virtual_pointer_manager_v1` are both advertised, so a viewer that cannot
click is a viewer bug -- as it was: a full-window status overlay with
`display: grid` overriding the `hidden` attribute, invisible and on top,
swallowing every click.

**The cursor needs two flags, not one.** wayvnc omits the pointer from the
frame unless `--render-cursor` is given; with it, a client that also draws its
own shows two. noVNC's is turned off with `showDotCursor = false`.

## What was chosen

The viewer owns the size; this side owns only the scale.

- `wayvnc --render-cursor --websocket` serves the session.
- The viewer is a page, `ab/web/viewer.html`, a full-bleed noVNC screen with
  `resizeSession` on, opened in a chromeless (app mode) window of the host's
  own browser on its own profile -- which is also what makes the window ours
  to close, since app mode launched into a running Chrome exits immediately.
- `geometry.py` shrinks to one job: give the output the host screen's scale,
  read from wlr-randr (fractional) or core `wl_output` (integer).
- Deleted with the old approach: the window-measuring probes and their
  compositor IPC, the remembered geometry, the reconnect-to-fit dance,
  `AGENT_BROWSER_GEOMETRY_CMD`, `AGENT_BROWSER_VNC_SIZE`, and wlvncc itself.

## Verified

With nothing configured, on a tiled 889x1081 window:

| | before | after |
|---|---|---|
| framebuffer | 1280x720 @ 1 | 1423x1730 @ 1.6, asked for by the viewer |
| canvas | -- | backing 1423x1730 shown at 889x1081 CSS: 1:1 device pixels |
| Chrome | 1280x720, dpr 1 | 889x1081, dpr 2 |
| on a window resize | nothing | framebuffer follows (1786 CSS -> 2858 device px) |
| border | large, top and bottom | none |

The size now survives things the old approach could not: the window being
resized after connecting, a second show, and a viewer that reconnects.
