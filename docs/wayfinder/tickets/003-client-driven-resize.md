---
id: 003
title: Why wayvnc refuses the client's resize request
labels: [wayfinder:research]
status: open
assignee:
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
