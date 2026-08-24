---
id: 057
title: Delete the CLI door
labels: [wayfinder:task]
status: open
assignee: lyh (via Claude)
blocked_by: []
---

## Question

There is no CLI user. Asked directly, the owner has never run it -- not once --
and nothing mechanical runs it either: no test invokes it, `skills/` never
mentions it, and the flake registers `apps.mcp` with Claude Code while
`apps.default` points at a binary nobody launches. The profile this whole tool
exists to keep warm was logged in through the *MCP* door, by asking an agent to
`openLane`, `script` to the login page and `showBrowser` -- so even the one
workflow the CLI was shaped around (`README.md:12`, "`passenger open <url>
--show` ...to log in by hand") has never been performed.

So this is not [026](026-one-description-two-doors.md)'s question of how to keep
two doors in step. It is the observation that the second door was never opened.

It is also where the map was already heading. [046](046-retire-fetch.md) and
[048](048-pictures-on-demand.md) each trimmed the CLI to match the MCP surface
and each recorded the same trade in the same words -- "symmetry chosen over a
human's convenience." Taken to its end, symmetry with a surface nobody uses is
deletion.

## What goes

Everything in `src/Passenger.Cli` except one verb, and the project with it.

`script`, `tabs`, `open`, `close-tabs`, `serve`, `show`, `hide` and `status` all
go. Six of those duplicate an MCP tool; the other two are examined below.

**`serve` goes.** It is already redundant: `EnsureDaemonAsync` sits on eight of
the ten MCP tools and calls `Browser.StartAsync(detach: true, hidden: true)`,
which is exactly bare `serve`. `README.md:69` ("A human runs `serve` first; an
agent should not have to know that") describes a world that ended when the
daemon learned to start on demand.

Its two flags are the only thing it still held, and one of them does not work.
`--foreground` says "Keep the daemon attached to this terminal"; `Spawn`
(`Browser.cs:146`) always redirects Chrome's stdout and stderr into pipes and
only *drains* them when `detach` is true -- nobody ever reads them, and
`StartAsync` returns and the process exits either way. Chrome's output has gone
nowhere in both modes since the port. That the broken half was never noticed is
more evidence for this ticket than against it.

Nothing replaces it. When Chrome fails to start, `DaemonStartFailed` already
carries `string.Join(" ", plan.Argv)` as its detail, so the failure hands over
the exact command line to paste into a shell -- which is strictly more than
`--foreground` ever delivered. Teeing Chrome's stderr to a file under the state
dir was considered and declined: real value, wrong ticket.

**`status` goes, and one field moves.** `browserStatus` already reports
`daemon`, `presenter`, `onScreen`, `profile`, `session`, `vnc`, `tabs`, `wedged`
and `screenClaims`. The CLI's `status` has two fields it does not: `launch:`
(which window backend was selected) and `recognises:` (the wall signature
table). They also diverge the other way -- `status` never printed
`screenClaims` -- which is one more 026 disagreement nobody had logged.

`launch` moves into `browserStatus`. `recognises` is deleted rather than moved:
[020](020-how-thin-can-this-layer-get.md) ruled that a fixed table does not
deserve a round trip, which is why `list_blockers` stopped being a tool, and
`SKILL.md:241` and the `script` tool description already list the same seven
signatures. Moving it into `browserStatus` would resurrect exactly what 020
killed and make a fourth copy. `README.md:169` says "`passenger status` prints
the table" and is rewritten to point at the skill.

**The reserved `cli` lane goes.** `Lanes.Cli` (`Lanes.cs:110`) has one
non-test consumer -- the `--lane` default at `Program.cs:36` -- and the comment
at `Lanes.cs:101` justifies it by the workflow being deleted: "a human at a
terminal runs `passenger open <url>` and then `passenger script --tab <id>`
thirty seconds later, from two separate processes." With no writer it is a
reserved id that exists to be swept. `orphan` is untouched; it holds the tabs a
human opens during a handoff and its reason survives all of this.
`LanesTests.cs:47` and `:114` become orphan-only assertions.

## What stays, and why exactly one thing does

`stop`, and nothing else.

The MCP door can start the daemon and diagnose it, but it cannot kill it, and
`Browser.Stop()` is the only exit from a wedged Chrome. Making it an MCP tool
was considered and rejected on the rule this codebase has already applied twice:
destructive things a human should own do not get an agent tool. It is the same
reasoning that made `hide --force` human-only and that made
[040](040-a-lane-owns-its-tabs.md) refcount the screen so one lane cannot take
the window from another lane's human. An agent that hits a timeout and helpfully
restarts Chrome costs the owner every login on the machine.

**It folds into `Passenger.Mcp` as a verb.** `src/Passenger.Cli` is deleted
outright -- project, csproj and the System.CommandLine dependency, which leaves
the repo entirely rather than moving. `Passenger.Mcp stop [--force]` is handled
beside `Webserve.ServeIfAsked(args)` at `Passenger.Mcp/Program.cs:19`, which is
already an argv check that runs before the host is built and before anything can
touch stdout. `--serve-viewer` stays flag-shaped because nothing but the process
itself ever types it; `stop` is verb-shaped because a human does.

Bare invocation must remain stdio -- that is the invariant. Unrecognised
arguments print two lines of usage to **stderr**, never stdout, and exit
non-zero, so that `Passenger.Mcp --help` does not silently start a server and
appear to hang.

**`stop` becomes conditional.** Today `Browser.Stop()` (`Browser.cs:256`)
terminates every Chrome on the profile dir and tears down the session without
consulting lanes at all, so typing it mid-handoff kills someone's work
silently. It should sweep, then refuse when a lane holds the screen
(`Lanes.ScreenClaims()`) or when a real lane still owns a live tab, saying how
many lanes and tabs are at stake. `--force` overrides, exactly as it does on
`hide`.

Two mechanics matter. `Lanes.Counts()` cannot be the trigger: Chrome launches
with `about:blank` (`Browser.cs:110`), so `LiveTabs()` returns at least one tab
whenever the daemon is up, and `orphan` is where that lands -- the check has to
be per-lane, excluding the reserved ones. And `Counts()` swallows its exception
and returns `(0, 0)` when Chrome does not answer, so a wedged Chrome degrades to
"nothing to lose" and `stop` simply works, which is the case it exists for. The
refusal only bites when Chrome is healthy. There is no "list the live lanes"
query on `Lanes` today -- only `Expired()` and `ScreenClaims()` -- so this is
the one small addition the ticket needs.

## The remedies have to be rewritten, and one of them never arrived

Three strings in core name commands that will not exist: `Browser.cs:298` and
`Present.cs:160` say "start it with: `passenger serve`", and `Browser.cs:373` --
ticket [042](042-attach-hangs-on-pending-navigation.md)'s carefully hedged
message -- says "`passenger status` says what is open, and `passenger stop`
restarts chrome at the cost of the warm session."

`DaemonNotRunning` loses its suggestion entirely. The daemon starts on demand,
so reaching that throw means the start failed or Chrome died mid-call, and there
is no command that fixes it. 042's message points at `browserStatus` and then
asks the agent to ask the human to run `Passenger.Mcp stop` -- the first place
here where a tool tells an agent to have a person type something, which is the
same shape as `showBrowser` aimed at the machine rather than the page.

**And the harder half.** `PassengerException` (`Errors.cs:64`) puts only
`[code] message` in `Message` and keeps `Detail` as a separate property. The CLI
prints it on a second line (`Program.cs:314`); `Tools.cs` catches nothing, so
the SDK reports `Message` alone. **042's detail -- which lanes are stuck and on
what URLs -- has never reached an agent.** It has only ever been visible at the
door nobody used.

So the MCP door must start catching `PassengerException` and folding code,
message and detail into what it returns. This is a prerequisite of the deletion,
not an improvement alongside it: without it, deleting the CLI silently throws
away the diagnostic 042 was written to produce.

## Packaging and docs

`meta.mainProgram`, `apps.default` and `executables` all become `Passenger.Mcp`,
and `apps.mcp` is removed rather than aliased -- one binary, one app, one name.
The cost is that `nix run /path/to/passenger#mcp` stops resolving, so every
machine's Claude Code registration needs its line changed to `nix run
/path/to/passenger`. Worth doing in the same sitting: the failure mode is a
server that does not come up, which is slow to trace back to a flake attribute.
The dev shell hint (`flake.nix:192`) points at a project that will be gone.

The README opens with a seventeen-line CLI quickstart, every line of which is
deleted; the MCP registration, currently buried under "As an MCP server",
becomes the quickstart. `README.md:71` -- "**`showBrowser` exists at all.** The
CLI has nothing like it on purpose" -- is deleted rather than corrected. It went
stale when the port gave the CLI a `show` verb, and with no CLI there is no
comparison left to draw.

## What this does to 026

It closes it, by subtraction rather than by argument. 026 wanted one declarative
description that both doors generate from, so a capability added at one could
not go missing at the other. With one door there is nothing to keep in step.

Two things die with it. The single live disagreement 026 had left --
whether `until="unblocked"` belongs on `passenger show`, the one `showBrowser`
parameter that [018](018-asking-for-a-human.md)'s "the caller is already the
human" argument does not cover -- is moot, because there is no `show`. And a
cheaper alternative to the generator, examined at length before this ticket
existed and worth recording since it was nearly built: a conformance test that
reflects over both doors, subtracts the parameter lists and fails unless every
difference is declared in one file with its reason. It would have made a missing
parameter impossible to add silently, which is 026's actual stated goal, for
about forty lines and no indirection. It needs two doors.
