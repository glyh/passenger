---
id: 033
title: Rename agent-browser to passenger
labels: [wayfinder:task]
status: open
assignee: lyh (via Claude)
blocked_by: []
---

## Question

`agent-browser` names the category, not the thing. Every tool an agent
can call is an agent-something, and every one of them that touches the
web is a browser, so the name carries no information: an agent reading a
tool list learns nothing from it, and neither does a person.

`passenger` is chosen. What this tool actually is, is a seat in a car
someone else is driving. It reads the web from a session a human owns and
stays warm by never doing anything unusual; when the road is blocked it
does not grab the wheel, it asks the driver to take over. That is
[Asking for a human](018-asking-for-a-human.md) and it is the whole
handoff design -- `show_browser` deliberately never rules on whether the
challenge was solved, because the passenger does not get to say. It is
also the standing advice in the server instructions, that reading is free
and driving spends the session's reputation.

    passenger fetch <url>
    passenger show
    passenger-mcp

What is open is the blast radius, not the name.

Out, mechanically: `pyproject.toml` name and both console scripts,
`flake.nix` (`pname`, `mainProgram`, the two apps, the checks
derivation, the dev shell banner), `MCPServer(name=)` in
`ab/mcp_server.py`, `Typer(name=)` in `ab/cli.py`, the `agent-browser
serve` / `agent-browser stop` / `agent-browser show` hints spoken in
`browser.py`, `present.py`, `service.py` and `cli.py`, `WM_CLASS` and the
generated-file banner in `launch.py`, the viewer's
`--class=agent-browser-viewer`, and the README throughout. Closed tickets
keep the old name where they used it -- they are the record of what was
true then, and 002, 010, 011, 013, 024 and 026 are not rewritten.

To decide:

1. **What happens to the state dir.** `~/.local/share/agent-browser` holds
   the Chrome profile, and that profile *is* the product -- it is the
   logged-in session everything else exists to protect. A rename that
   silently points at a fresh directory logs the user out of every site at
   once and looks like the tool broke. Options: move the directory on
   first start when the old one exists and the new one does not; read the
   old path as a fallback forever; or leave the state dir named
   `agent-browser` and accept the seam. The move is only safe with the
   daemon down, so whatever is chosen has to say what happens when it is
   not.
2. **Whether `AGENT_BROWSER_*` becomes `PASSENGER_*`.** Same shape of
   problem, cheaper: they are read in exactly one place (`config.py`), so
   accepting both with the old one deprecated is a few lines. The flake
   sets three of them and would move in the same commit.
3. **Whether the `ab/` package is renamed.** `ab` is an abbreviation of
   the old name and stops meaning anything. It is also every import in
   the codebase and every patch target in the tests, and it is not user
   visible. `passenger/` is the honest answer; `ab/` is the cheap one.
4. **How the MCP registration is migrated.** Renaming the server changes
   the tool names an agent sees (`mcp__agent-browser__fetch` →
   `mcp__passenger__fetch`), which no amount of care makes seamless: the
   user re-runs `claude mcp add` once, and any agent memory naming the old
   tools is stale. Worth a line in the README rather than a mechanism.
5. **Whether the directory and the repo move too.** No remote, so this is
   a `mv` and a note; the memory index and any host paths in
   `claude mcp add` point at the old one.

Recommendation: rename everything user-facing in one commit, move the
state dir on first start with the fallback kept for a while, take
`PASSENGER_*` while accepting `AGENT_BROWSER_*`, and rename `ab/` in a
second commit of its own so the mechanical churn does not hide the real
change.
