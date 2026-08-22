---
id: 003
title: Whether the viewer can drive the resize itself
labels: [wayfinder:research]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

Sizing the output currently depends on knowing how big to make it, and the
only way to get that exactly right for a windowed viewer is a command the
user writes themselves ([Sizing the cage output to the viewer's real window
and scale](002-vnc-output-sizing.md)). None of that would be needed if the
viewer could ask for its own size, which is what RFB already specifies and
what wayvnc claims to support -- its automatic resizing is on by default.

It does not work. TigerVNC with `-RemoteResize=1` is answered:

    CConnection: SetDesktopSize failed: 4

Nothing was investigated beyond observing the refusal.

- What is result code 4 here, and which side decides it? The RFB
  `ExtendedDesktopSize` codes run 0 success, 1 prohibited, 2 out of
  resources, 3 invalid layout -- so 4 is either a newer code or wayvnc's
  own.
- Does wayvnc's automatic resizing require something absent here -- a
  transient seat, `--detached`, a single-screen layout, a capability cage
  does not advertise?
- Does it work against a different compositor, which would place the
  refusal in cage rather than wayvnc?
- Is TigerVNC requesting a multi-screen layout that a single headless
  output cannot satisfy?

If this can be made to work, `AGENT_BROWSER_GEOMETRY_CMD` becomes
unnecessary for any client that supports remote resize, and the viewer's
window is fitted continuously rather than once per `show`.

## Answer

**It is not refused. The log line lies.** TigerVNC prints
`CConnection: SetDesktopSize failed: 4` and the resize happens anyway, in the
same second:

    DesktopWindow: Requesting framebuffer resize from 1200x1200 to 1422x1730
    CConnection: SetDesktopSize failed: 4
    Viewport:    Resizing framebuffer from 1200x1200 to 1422x1730

Started against a deliberately wrong 1280x720 output, TigerVNC drove it to
1422x1730 -- its own window in physical pixels -- with no help from this side.
noVNC does the same: a viewport of 1000x1400 produced exactly that framebuffer,
and 900x1500 exactly that.

So the refusal that sent
[Sizing the cage output](002-vnc-output-sizing.md) down the measure-it-yourself
road was never real; nothing was wrong with wayvnc, cage, or the protocol. What
was wrong was reading one log line as the outcome and not checking the
framebuffer afterwards.

The remaining sub-questions are moot -- there is no refusal to explain -- with
one worth recording: code 4 is outside the RFB spec's 0--3, so it is wayvnc's
own, and it evidently does not mean failure.

`AGENT_BROWSER_GEOMETRY_CMD` is gone, along with every other way this tool had
of guessing a window size.
