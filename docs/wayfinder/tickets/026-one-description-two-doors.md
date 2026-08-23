---
id: 026
title: One description, two doors
labels: [wayfinder:grilling]
status: open
assignee:
blocked_by: []
---

## Question

The CLI and the MCP server are two hand-written surfaces over the same
service layer, and they have drifted. [Asking for a human, rather than
being guessed at](018-asking-for-a-human.md) added `tab`, `wait_seconds`
and `notify_human` to the MCP `show_browser` and deliberately did not
mirror any of them onto `agent-browser show`, because mirroring three
flags by hand is the symptom rather than the fix.

The drift is older than that ticket. `fetch` on the CLI takes
`--keep-tab`, `--close-tabs`, `--new-tab` and `--wait`, none of which the
MCP `fetch` exposes; the MCP `fetch` takes `wait_seconds`, which the CLI
spells `--handoff` plus a setting; `script` exists at both doors with
different parameter names for the same thing. Every one of those is a
defensible local choice, and together they mean a capability added in one
place is silently absent in the other, with nothing that fails when it is.

What is wanted is a single declarative description of each capability --
its parameters, their types, bounds, defaults and prose -- that both
`cyclopts` and the MCP tool schema are generated from, so the two doors
cannot disagree by accident.

To decide:

1. Where the source of truth lives. The request models in `ab/models.py`
   are the obvious candidate: `FetchRequest` and `ScriptRequest` are
   already pydantic, already carry bounds, and are already what the
   service layer takes. `show_browser` has no request model at all, which
   is part of why it drifted -- so this may be as much about giving every
   capability one as about generating from it.
2. What the description has to express that a pydantic model does not.
   Per-door prose is the hard one: the MCP `fetch` docstring is written
   for an agent and says things a human at a terminal does not need, and
   `--help` wants a line where a tool schema wants a paragraph.
3. Whether the two doors genuinely want the same parameters. 018 argued
   they do not: `wait_seconds` and `notify_human` are ways of reaching a
   human who is not the caller, and on the CLI the caller *is* the human.
   If that is right, the description needs a way to say "this door only",
   and the interesting question becomes whether that escape hatch gets
   used honestly or becomes where drift hides again.
4. What this costs in indirection. Two hand-written surfaces are dumb and
   readable; a generator is neither. It has to pay for itself in more than
   tidiness -- the case is that a missing parameter is currently invisible,
   and generation makes it impossible rather than merely noticed.
5. Whether it survives [Whether this moves to
   C#](023-rewriting-into-csharp.md). If the port happens, a Python
   generator is thrown away -- but the *problem* is not, and a port is
   exactly the moment a second surface gets rebuilt by hand from the
   first. Worth knowing whether this is a thing to do now or a thing the
   port should be told about.
