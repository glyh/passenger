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

**Superseded once, then answered properly.** The first answer sized the output
from this side on `show`, once the viewer was up. It was wrong in a way that
only showed on screen: the reported size matched the window while the *picture*
did not, and it was reported as verified on the strength of the framebuffer,
which matches by construction. See
[the findings](../assets/002-vnc-sizing-findings.md) for the measurements.

The viewer owns the size. noVNC asks for the framebuffer its window needs over
RFB `SetDesktopSize`, wayvnc answers through cage's wlr-output-management, and
the framebuffer keeps following the window -- including while it is dragged to
a new size. This side keeps only the scale, which no client can ask for.

`SetDesktopSize failed: 4` turned out not to mean refusal at all, which is what
had ruled this out:
[Why wayvnc refuses the client's resize request](003-client-driven-resize.md).

On the design questions the ticket raised:

1. **Where the size comes from.** The viewer's own window, asked for by the
   viewer. Measuring it from this side was tried first -- host compositor IPC
   per desktop, a user-supplied command, the whole screen as a fallback -- and
   every version of it lost the same race: wayvnc advertises a resize to
   clients some time after `wlr-randr` returns, and a client connecting in that
   gap keeps the stale size. There is no signal to wait on, and a client that
   asks for itself needs none.
2. **Dynamic or once.** Continuous, and for free: every window resize re-asks.
3. **Whether a resize disturbs the page.** It does not. Chrome reflows within a
   second, in both directions, and keeps the page. Its JS `innerWidth` goes
   stale, but layout and frame are correct.
4. **Fingerprint.** Improved, not merely neutral. 1280x720 at dpr 1 is an
   unusual browser window; 889x1081 at dpr 2 on a scaled panel is what an
   ordinary laptop reports.

What the answer costs: the local presenter is no longer a native VNC client but
a chromeless window of the host's own browser, on a profile of its own -- which
is also what makes it ours to close. The whole client side went from 328 MiB of
native client to 1.4 MiB of static JavaScript, and `geometry.py` from 552 lines
of window-measuring to 160 lines that set a scale.

Two cursor defects surfaced while testing and were fixed with it, since a
handoff you cannot point during is as broken as one you cannot read: wayvnc
omits the pointer from the frame without `--render-cursor`, and with it a
client drawing its own shows two -- so the viewer page sets
`showDotCursor = false`.

Measured on the reporting machine, with nothing configured: the viewer asks for
1423x1730 to fill an 889x1081 window, its canvas holds 1423x1730 device pixels
shown across 889x1081 CSS pixels (1:1), Chrome reports 889x1081 at dpr 2, and
resizing the window to 1786 CSS pixels moves the framebuffer to 2858.
