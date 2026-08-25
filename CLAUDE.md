# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`passenger` is an MCP server, and nothing else. It hands agents web pages through a real,
logged-in Chrome that sites cannot distinguish from a human's daily driver, with a handoff to
a human when a site puts up a captcha or a login. One entry point: `src/Main.res.mjs`, stdio.

Read `README.md` first — it carries the design reasoning, the tool list, the `PASSENGER_*`
environment surface, and why there is no `fetch` and no CLI any more.

## Build, test, run

The server is ReScript compiled to ES modules and run by node. Everything happens inside the
nix dev shell (direnv loads it on `cd`):

    nix develop                       # or let .envrc do it
    npm install                       # once, and after package.json moves
    npm run build                     # rescript build -- emits src/*.res.mjs beside each source
    npm run watch                     # the same, incrementally
    npm test                          # build, then node --test over test/*_test.res.mjs
    node --test test/Detect_test.res.mjs                     # one suite
    node --test --test-name-pattern="a known signature" \
         test/Detect_test.res.mjs                            # one case
    node src/Main.res.mjs stop [--force]
    nix build                         # runs the suite as part of the derivation (doCheck)
    nix run .                         # the server, as a client launches it

`npm test` builds first, deliberately: a stale `.res.mjs` that still passes while its `.res`
no longer compiles is the failure mode an in-source build invites.

Warnings are errors here, set by `rescript.json`'s `compiler-flags` -- the same deliberate
choice `Directory.Build.props` carried before ticket 071.

**The emitted `.res.mjs` is a build artefact, not source.** It is readable on purpose, which
makes it worth reading when a binding misbehaves, but it is gitignored and regenerated from
the `.res` beside it. Never edit one.

Some checks need a browser, a real noVNC, or a human, so they are not tests. They are scripts
at the root, and each says at the top what it needs and why it cannot be one:

    node probe.mjs          # the ten tools over stdio, needs Chrome on 9222
    node live-session.mjs   # Session, and that Playwright's handles still match Script's rule
    node live-webserve.mjs  # the viewer server's routes, needs a real noVNC
    node live-handoff.mjs   # the whole handoff path, opening no window

**Nothing in this process may write to stdout except the protocol.** The server speaks
JSON-RPC on stdio. The flake's shellHook prints to stderr for that reason, and
`nix develop --command` forwards hook output to stdout — which is why the documented
registration uses `nix run`.

## Architecture

Functional core, imperative shell. The core is pure and testable without a browser; anything
touching Chrome, the disk, the clock or a subprocess is shell.

    core   Models.res    every boundary shape, as records and variants
           Detect.res    blocked-or-not, given a probe measurement
           Errors.res    the codes, and the one structural exception
           Geometry.res  the two parsers a scale is discovered through
           Script.res    compiling a caller's JavaScript; deciding what may cross back

    shell  Service.res   the one script orchestration
           Session.res   attaching Playwright, and the rescue when a tab wedges it
           Browser.res   Chrome daemon lifecycle
           Lanes.res     which lane owns which tab, and when its time is up
           Targets.res   Chrome's targets over CDP, going around Playwright
           Probe.res     measuring a live page into a probe record
           Handoff.res / Present.res / Launch.res / Sessions.res / Webserve.res / Notify.res
                         summoning a human: sway + wayvnc + the noVNC viewer page
           Fs.res / Proc.res / Posix.res / Sqlite.res / Timers.res / WebSocket.res / Node.res
                         the runtime, bound thinly -- what the BCL used to supply

    door   Main.res      the ten tools, the two argv checks, and the whole surface there is
           Stop.res      the one verb a human types
           Mcp.res / Pw.res   the SDK and Playwright, bound to what the shell touches

Detection is pure because the shell measures first: `Probe.measure` tests candidate selectors
against the live page into a record, so `Detect.classify` is a function of that record alone.
Blockers, error codes and wedges are real variants, so an unhandled case in a `switch` is a
compile error -- which is the property the C# side had to spell as a base record with a `type`
discriminator, and the reason ticket 071 required a *sound* compile-to-JS language rather than
plain JS or TypeScript.

**Until ticket 071 this was C#, and its test suite was the oracle for every module here.**
Each file in `test/` names the `tests/Passenger.Tests/*.cs` it was ported from, case for case;
that tree is gone, and those names are now history rather than a path.

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
- **What crosses that door is JavaScript, and what comes back is JSON.** A caller's source
  runs in a `node:vm` context with `Page` bound, plus the short list `Script.globals` names --
  and `fetch` is deliberately absent from it, because a second way onto the web that goes
  around the browser is what ticket 046 deleted. `Script.handleName` refuses a live Playwright
  handle by a rule measured off the objects, not a list of them; the list is what let an
  `IAPIResponse` through on the C# side and serialised the driver's internals as an answer.
- **A lane owns its tabs.** One Chrome is shared by every agent on the machine; `openLane` is
  required rather than defaulted, because a caller isolated by accident cannot tell which lane
  it is in.
- **Operating knowledge lives in `skills/using-passenger/`,** not in tool docstrings. The
  docstrings carry the call contract and stop there; the skill carries what `blocked` does not
  catch, how to recognise a wall this side cannot name, and that a read is only the first
  screen. `SKILL.md` is the judgement, `references/` the mechanics, `scripts/` the recipes
  (`markdown.js`, `unstrip-asides.js`, `pictures.js`) that a caller reads off disk and runs in
  a page.
- **`skills/` ships three, and they are not peers.** `using-passenger` is this server's own
  operating knowledge, and is the only one the tool docstrings assume. `html-to-markdown` is a
  converter a caller reaches for once it has HTML in hand -- it fetches nothing. And
  `passenger-skill-authoring` is a level up: how to *write* a scraping skill for a site, which
  is what a caller ends up doing after the second time it works a site out from scratch. A site's
  own skill lives with that caller, not here; this repo carries only what is true of the tool.

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
