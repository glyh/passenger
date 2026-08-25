# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`passenger` is an MCP server, and nothing else. It hands agents web pages through a real,
logged-in Chrome that sites cannot distinguish from a human's daily driver, with a handoff to
a human when a site puts up a captcha or a login. One binary: `Passenger.Mcp`, stdio.

Read `README.md` first — it carries the design reasoning, the tool list, the `PASSENGER_*`
environment surface, and why there is no `fetch` and no CLI any more.

## Build, test, run

Everything happens inside the nix dev shell (direnv loads it on `cd`):

    nix develop                       # or let .envrc do it
    dotnet build Passenger.slnx
    dotnet test tests/Passenger.Tests
    dotnet test tests/Passenger.Tests --filter FullyQualifiedName~DetectTests
    dotnet test tests/Passenger.Tests --filter "FullyQualifiedName~DetectTests.AKnownSignatureStillMatches"
    dotnet run --project src/Passenger.Mcp -- stop [--force]
    nix build                         # runs the test suite as part of the derivation (doCheck)
    nix run .                         # the server, as a client launches it

`dotnet` outside the dev shell will fail to restore: the ModelContextProtocol packages are a
local fork, and `Directory.Build.props` only finds them when `MCP_SDK_NUGET_SOURCE` is set,
which the dev shell does. When NuGet deps move, regenerate the lockfiles with
`nix build .#default.passthru.fetch-deps` (and `.#mcp-sdk.passthru.fetch-deps` for the fork).

`TreatWarningsAsErrors` is on with nullable reference types enabled — a warning fails the
build, deliberately (`Directory.Build.props` says why).

**Nothing in this process may write to stdout except the protocol.** The server speaks
JSON-RPC on stdio. The flake's shellHook prints to stderr for that reason, and
`nix develop --command` forwards hook output to stdout — which is why the documented
registration uses `nix run`.

## Architecture

Functional core, imperative shell. The core is pure and testable without a browser; anything
touching Chrome, the disk, the clock or a subprocess is shell.

    core   Models.cs    every boundary shape, as frozen records
           Detect.cs    blocked-or-not, given a PageProbe measurement
           Errors.cs    ErrorCode + structural errors
           Script.cs    compiling a caller's C# with Roslyn; deciding what may cross back

    shell  Service.cs   the one script orchestration
           Browser.cs   Chrome daemon lifecycle, CDP attach
           Lanes.cs     which lane owns which tab, and when its time is up
           Targets.cs   Chrome's targets over CDP
           Probe.cs     measuring a live page into a PageProbe
           Handoff.cs / Present.cs / Launch.cs / NestedSessions.cs / Webserve.cs
                        summoning a human: cage + wayvnc + the noVNC viewer page

    mcp    Passenger.Mcp/Program.cs   viewer re-exec, `stop`, then the server
           Passenger.Mcp/Tools.cs     the ten tools, and the whole surface there is

Detection is pure because the shell measures first: `Probe.Run` tests candidate selectors
against the live page into a `PageProbe`, so `Detect.Classify` is a function of that record
alone. Blockers are a discriminated union (a base record with a `type` discriminator, since
C# has none), so an unhandled case in a `switch` expression is a compile error.

## Load-bearing rules

These are settled decisions with tickets behind them. Breaking one is a design change, not a
cleanup.

- **The tool measures; the caller judges.** This side reports what it measured — since ticket
  048, one thing: a challenge vendor's own markup — and never rules on what a page *means*.
  Six mechanisms have been deleted for crossing that line (a yield floor, a `min_words` tier,
  a learned signature registry, an `auto` mode, a wall hint, a withheld-content reporter).
  Extraction lives in the skill as a recipe, not here as a mode.
- **The tool does not learn.** Nothing durable about a *site* is stored on this side. A tool
  that remembers is a second memory owned by the wrong party. The builtin signature table is
  fixed at build time and identical on every machine.
- **One door onto a page.** `script` — no tool per Playwright verb (ticket 004), no `fetch`
  (046). Adding a second way to do something already reachable through `script` needs a
  ticket's worth of justification.
- **A lane owns its tabs.** One Chrome is shared by every agent on the machine; `openLane` is
  required rather than defaulted, because a caller isolated by accident cannot tell which lane
  it is in.
- **Operating knowledge lives in `skills/using-passenger/`,** not in tool docstrings. The
  docstrings carry the call contract and stop there; the skill carries what `blocked` does not
  catch, how to recognise a wall this side cannot name, and that a read is only the first
  screen. `SKILL.md` is the judgement, `references/` the mechanics, `scripts/` the recipes
  (`markdown.js`, `unstrip-asides.js`, `pictures.js`) that a caller reads off disk and runs in
  a page.

## Working in this repo

Issues live in the repo as markdown — no remote, no hosted tracker. `docs/agents/issue-tracker.md`
is the full convention; the short version:

    docs/wayfinder/frontier.sh                          open, unassigned, unblocked tickets
    docs/wayfinder/frontier.sh new <slug> "<title>"     allocate an id — never pick one by hand

Claim a ticket (set `assignee`) and commit before doing the work; resolve by appending an
`## Answer` section, setting `status: closed`, and adding a one-line pointer to the map's
Decisions-so-far in `docs/wayfinder/map.md`. Ids collided four times when sessions picked them
by reading the directory, which is why `new` claims via exclusive create instead.

Single developer, no remote: commit to `trunk`, do not branch. Commit subjects read as
`Claim NNN: ...` / `Close NNN: ...` when a ticket is involved.

Comments explain *why*, at length, and when one guards against a regression it says what the
prior wrong behaviour was. Match that — this codebase's comments carry the history that a
hosted tracker would.
