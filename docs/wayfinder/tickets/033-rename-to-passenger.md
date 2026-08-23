---
id: 033
title: Rename agent-browser to passenger
labels: [wayfinder:task]
status: closed
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

## Answer

Renamed, in two commits. `passenger` and `passenger-mcp` are the console
scripts, `passenger` is the MCP server and the cyclopts app, `WM_CLASS` and
the viewer's `--class` and the viewer page's title are `passenger` and
`passenger-viewer`, and `skills/using-agent-browser` is now
`skills/using-passenger`, with the vault symlink repointed at it. The flake
moved with them: description, `pname`, `mainProgram`, both apps, the checks
derivation and the dev-shell banner. Closed tickets keep the old name, and
so do the two lines of the map that narrate a command and a variable that
no longer exist.

On the five open questions:

1. **The state dir is not migrated, and the repo no longer mentions the old
   path at all.** `~/.local/share/passenger` is simply the default now. The
   1.5G logged-in Chrome profile is kept by a symlink made by hand outside
   the tree — `ln -s agent-browser ~/.local/share/passenger` — which is safe
   with the daemon up precisely because nothing is copied and no process is
   asked to let go of anything. Verified against the live daemon: `status`
   reports the profile under the new path and every logged-in tab is still
   there. The move-on-first-start option in the question was refused for
   what it would have left behind: migration code is read by everyone
   forever to protect a case that happens once, on one machine, and it can
   only run safely with the daemon down, which is a precondition the tool
   would have had to police.

2. **`PASSENGER_*` with no alias.** Accepting `AGENT_BROWSER_*` as a
   deprecated spelling is a few lines, and those few lines are permanent:
   the variables are read in exactly one place, and the flake is the only
   thing that sets them, so the shim would outlive the confusion it exists
   to prevent by years.

3. **`ab/` is now `passenger/`,** in a commit of its own, along with
   `AgentBrowserError` → `PassengerError`. Every import, both entry points,
   the wheel's package list, `pythonImportsCheck`, the two
   `resources.files("passenger")` lookups that read `pictures.js` and
   `walker.js` out of the package, and the `-m` module the noVNC helper
   respawns itself as. `mypy --strict` clean, 54 tests pass.

4. **The MCP registration is re-run by hand.**
   `mcp__agent-browser__fetch` is `mcp__passenger__fetch`, which no mechanism
   makes seamless. Note that the registered command was
   `python -m ab.mcp_server`, so an unchanged registration does not merely
   keep the old tool names — it fails to start. This ticket is where that is
   written down: the README does not mention the old name anywhere, because a
   README describes what the tool is, not what it was, and this rename is the
   record of the change.

5. **The checkout stays at `/home/lyh/agent-browser`.** Moving it invalidates
   the MCP registration's two absolute paths and the vault skill symlink in
   the same moment, for a directory name no agent and no tool reads. Left as
   a `mv` and a note for whenever the registration is being edited anyway.
