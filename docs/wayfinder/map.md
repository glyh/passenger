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

_None yet._

## Fog

- **The whole `web` presenter path is unexercised.** `WebPresenter`
  hands back a noVNC URL and checks the port is open, but nothing here
  has ever run noVNC. Whether that path works at all is unknown, and it
  is the only option for a containerised deployment.
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
- **Input quality during handoff, not just output.** Sizing is charted;
  keyboard layout, clipboard, and IME through the VNC path are not, and
  a login the human cannot type into fails just as hard as one they
  cannot see.
- **Nothing notices a session dying mid-fetch.** `reap_stale` runs at
  start. A crash between fetches is only discovered on the next one.
