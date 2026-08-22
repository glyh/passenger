---
id: 002
title: Sizing the cage output to the viewer's real window and scale
labels: [wayfinder:research]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

The nested compositor renders at a fixed size that has nothing to do with
the screen it is eventually viewed on, so the human handoff -- the case
this tool exists for -- is shown through a small, letterboxed, upscaled
image.

Measured on this machine:

- Panel `eDP-1`: **2880x1800 @ 120Hz, scale 1.6** (logical 1800x1125)
- cage headless output: **1280x720**, and Chrome reports
  `devicePixelRatio: 1`

So the viewer receives a 1280x720 frame: black border around it, and
every pixel resampled on a HiDPI panel. Text in a captcha or a login form
is exactly what suffers.

Research what the installed stack can actually do about it, then
recommend an approach:

- Does **cage 0.3.1** expose `wlr-output-management` so the headless
  output can be resized at runtime (`wlr-randr`), or is the size fixed
  for the compositor's lifetime? Is `WLR_HEADLESS_OUTPUTS` size-settable?
- Does **wayvnc 0.10.1** support client-driven desktop resize
  (RFB `SetDesktopSize` / the `ExtendedDesktopSize` pseudo-encoding), and
  does that path require output-management support underneath?
- What does **wlvncc** do with a remote size that differs from its window
  -- letterbox, scale, or request a resize? Does it communicate the
  client's scale factor at all?
- Is `--force-device-scale-factor` on Chrome the right lever for
  crispness, independent of the output size question?

Open design questions the recommendation has to answer:

1. Where the target size comes from. The viewer's window is the honest
   source, but the session is launched long before any viewer connects,
   and `agent-browser show` is what knows the screen.
2. Whether the output resizes dynamically per viewer, or is simply
   launched at a sensible size derived from the host's screen.
3. Whether changing the output size mid-session disturbs Chrome or the
   page under it -- a resize during a challenge would be worse than a
   small window.
4. Whether a larger, higher-DPI output changes the browser fingerprint
   in a way that matters. A 2880x1800 window reporting dpr 1.6 is more
   ordinary than 1280x720 at dpr 1, so this likely helps -- but it is a
   deliberate change to what sites see, not a free win.

## Answer

The output is sized from this side, on `show`, once the viewer is up.

cage implements `wlr-output-management-v1`, so the headless output can be
reconfigured live -- Chrome follows without a restart and the connected
viewer picks up the new framebuffer. Client-driven resize, which would have
been tidier, is not available: wlvncc never asks for one, and TigerVNC asking
with `-RemoteResize=1` is answered `SetDesktopSize failed: 4`. See
[the findings](../assets/002-vnc-sizing-findings.md).

The target comes from the first source that answers:

1. `AGENT_BROWSER_VNC_SIZE` / `AGENT_BROWSER_VNC_SCALE` -- a pinned size.
2. `AGENT_BROWSER_GEOMETRY_CMD` -- a user-supplied command printing
   `WxH[@scale]`, which is how a tiled window gets fitted exactly.
3. `wayland-info` reading core `wl_output` -- the screen, which is exact
   when the viewer is fullscreen.

On the design questions the ticket raised:

1. **Where the size comes from.** Not the viewer's window directly: no
   Wayland protocol exposes another client's geometry, and the compositor
   IPC that would is different on every desktop. Rather than adopting one
   desktop and calling it support, that question is handed to whoever knows
   their own, through `AGENT_BROWSER_GEOMETRY_CMD`. The portable default is
   the screen, read from core `wl_output`.
2. **Dynamic or once.** On `show`, and again on a repeat `show` -- which is
   the way back to a fitted picture after moving or resizing the window.
   Not continuous: nothing watches the window.
3. **Whether a resize disturbs the page.** It does not. Chrome reflows and
   keeps the page. Doing it on `show` also puts the resize *before* the
   human starts interacting rather than during.
4. **Fingerprint.** Improved, not merely neutral. 1280x720 at dpr 1 is an
   unusual browser window; 889x1081 at dpr 2 on a scaled panel is what an
   ordinary laptop reports.

Two cursor defects surfaced while testing and were fixed with it, since a
handoff you cannot point during is as broken as one you cannot read:
wayvnc omits the pointer from the frame without `--render-cursor`, and with
it a client drawing its own shows two -- so wlvncc is started with `-n`.

Measured on the reporting machine: output 1280x720 @ 1 became 1422x1730 @
1.6, fitted to the actual tile; Chrome went from 1280x720 dpr 1 to 889x1081
dpr 2; the border is gone and one cursor is drawn.
