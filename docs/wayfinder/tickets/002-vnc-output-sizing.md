---
id: 002
title: Sizing the cage output to the viewer's real window and scale
labels: [wayfinder:research]
status: open
assignee:
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
