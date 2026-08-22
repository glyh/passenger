---
labels: [wayfinder:map]
---

# Making the nested browser stack trustworthy

## Notes

**Domain.** `agent-browser` fetches pages through a real, logged-in
Chrome that sites cannot distinguish from an ordinary browser. Chrome
runs inside its own `cage` compositor; `wayvnc` serves that compositor,
and a viewer is spawned on demand when a human has to take over -- solve
a captcha, log in. The value of the whole tool rests on two things: the
session staying warm and real, and the handoff to a human actually
working when it is needed.

**This effort.** The stack was recently found to be silently broken in
the handoff path: a stale `wayvnc` served a dead compositor while every
status read healthy, so `show` produced a black screen. That specific
correlation bug is fixed (commit 5275197 -- per-session port and control
socket, a session record written from inside cage, pid-scoped teardown).
What remains is everything that made it possible: no tests, and a
presentation layer nobody had looked at closely.

**Skills to consult.** `python-as-ocaml` and `python-design-patterns` --
the codebase is deliberately functional-core / imperative-shell, with
pydantic models parsed at every boundary and no raw dicts downstream.
Match that style rather than introducing a new one. `tdd` is relevant to
[What the test suite covers, and how the shells get tested](tickets/001-testing-the-shells.md).

**Standing preferences.** Docstrings explain *why*, and say what the
prior wrong behaviour was when a comment guards against its return.
Single developer, no remote: commit to `trunk`, do not branch.

## Decisions so far

<!-- one line per closed ticket -->

- [Sizing the cage output to the viewer's real window and scale](tickets/002-vnc-output-sizing.md)
  — the viewer owns the size and asks for it over RFB, continuously; this
  side keeps only the scale. The local presenter is now the viewer page in
  a chromeless window of the host's own browser, not a native VNC client.
- [Whether the viewer can drive the resize itself](tickets/003-client-driven-resize.md)
  — it can. `SetDesktopSize failed: 4` is printed and the resize happens
  anyway; the refusal that justified measuring windows from this side was
  never real.

## Fog

- **Two viewers fight over the framebuffer.** Now that the size is
  client-driven, every connected viewer asks for its own window's size,
  and the last to ask wins. Harmless with one viewer, which is the only
  case exercised; unclear what the right behaviour even is with two.
- **The `web` presenter is exercised only on this machine.** It is the
  same page and server the local presenter uses, so the path is no longer
  untested — but nothing has yet opened it from another machine, which is
  the case it exists for, and wayvnc's websocket is bound to localhost.
- **Pid reuse.** The session record trusts pids. Across a reboot, or
  after enough churn, a recorded pid could belong to something else
  entirely -- and `teardown` would SIGTERM it. A start time or cgroup
  check would pin identity properly. Unclear yet whether this is a real
  risk or a theoretical one.
- **One browser at a time is assumed everywhere.** The CDP port, the
  profile directory, and the session record are all single-valued. If
  concurrent sessions are ever wanted, that assumption is load-bearing
  in more places than it looks.
- **A long-running MCP server can hold stale code.** Editing `ab/` does
  not affect an already-running server, which is confusing precisely
  when someone is mid-debugging. Perhaps a version report in
  `browser_status`; perhaps nothing.
- **Input quality during handoff, not just output.** The pointer is now
  drawn and singular, but keyboard layout, clipboard, and IME through the
  VNC path are still unexamined -- a login the human cannot type into
  fails just as hard as one they cannot see.
- **Two Wayland operations shell out to CLI tools.** `wlr-randr` sets the
  output size and `wayland-info` reads the screen. Both are protocol
  operations that a binding could do in-process, but no Python library
  speaks wlr-output-management, and generating bindings for it would be a
  large dependency for a small tool. Worth revisiting if the parsing of
  either tool's human-readable output ever bites.
- **A fetch returns the whole page, and nothing bounds it.** For an
  agent, the page *is* the context budget: a listing of a hundred
  bankruptcy notices costs the same as the paragraph that mattered.
  There is no cap, no selector to scope the read, and no notice when
  something was long. Paging such a list a few times is enough to feel
  it. Whether the answer is a `max_words`, a scoping selector, or simply
  leaving it to the caller is unexamined -- but it interacts with
  [Reaching content that sits behind an interaction](tickets/004-driving-the-page.md),
  where a read-per-step multiplies the cost.
- **Nothing notices a session dying mid-fetch.** `reap_stale` runs at
  start. A crash between fetches is only discovered on the next one.
