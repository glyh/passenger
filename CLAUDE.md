# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`passenger` is an MCP server, and nothing else. It hands agents web pages through a real,
logged-in Chrome that sites cannot distinguish from a human's daily driver, with a handoff to
a human when a site puts up a captcha or a login. One entry point: `src/cli/Main.res.mjs`, stdio.

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
    node src/cli/Main.res.mjs serve       # what a client launches
    node src/cli/Main.res.mjs stop [--force]
    nix build                         # runs the suite as part of the derivation (doCheck)
    nix run .                         # the server, as a client launches it

`npm test` builds first, deliberately: a stale `.res.mjs` that still passes while its `.res`
no longer compiles is the failure mode an in-source build invites.

Warnings are errors here, set by `rescript.json`'s `compiler-flags` -- the same deliberate
choice `Directory.Build.props` carried before ticket 071.

**The emitted `.res.mjs` is a build artefact, not source.** It is readable on purpose, which
makes it worth reading when a binding misbehaves, but it is gitignored and regenerated from
the `.res` beside it. Never edit one.

Some checks need a browser, a real noVNC, or a human, so they are not tests. They live in
`live/`, they are **ReScript like everything else**, and each says at the top what it needs
and why it cannot be a test:

    node live/LiveDoor.res.mjs      # the ten tools over stdio, needs Chrome on 9222
    node live/LiveSession.res.mjs   # attaching, lane-scoped tabs, what handles serialise to
    node live/LiveTargets.res.mjs   # Targets and the live lane seam
    node live/LiveWebserve.res.mjs  # the viewer server's routes, needs a real noVNC
    node live/LiveHandoff.res.mjs   # the whole handoff path, opening no window

They were hand-written `.mjs` at the root until they were not, and the reason is worth
keeping: a `.mjs` that imports `src/**/X.res.mjs` is reaching into a build artefact, so it
binds itself to the compiler's calling convention -- optional arguments as trailing
`undefined`, exceptions as `{RE_EXN_ID}` -- and gets no types for any of it. Nothing outside
`live/` and `test/` should import a `.res.mjs`.

**Nothing in this process may write to stdout except the protocol.** The server speaks
JSON-RPC on stdio. The flake's shellHook prints to stderr for that reason, and
`nix develop --command` forwards hook output to stdout — which is why the documented
registration uses `nix run`.

## Architecture

Functional core, imperative shell. The core is pure and testable without a browser; anything
touching Chrome, the disk, the clock or a subprocess is shell.

The four directories under `src/` are that split, made a directory each. ReScript's
module namespace is flat regardless, so a move between them changes no `import` and
no reference -- the directories are for a reader, and the compiler does not care.

    src/core/      pure. No browser, no disk, no clock, no subprocess.
      Models.res     every boundary shape, as records and variants
      Detect.res     blocked-or-not, given a probe measurement
      Errors.res     the codes, and the one structural exception
      Script.res     compiling a caller's JavaScript; deciding what may cross back

    src/shell/     everything that touches the world.
      Service.res    the one script orchestration
      Session.res    attaching Playwright, and the rescue when a tab wedges it
      Browser.res    Chrome daemon lifecycle
      Lanes.res      which lane owns which tab, and when its time is up
      Targets.res    Chrome's targets over CDP, going around Playwright
      Probe.res      measuring a live page into a probe record
      Geometry.res   at what density the nested browser renders
      Config.res     the PASSENGER_* env boundary
      Assets.res     the four files read from `assets/`
      Handoff.res Present.res Launch.res NestedSessions.res Webserve.res Notify.res
                     summoning a human: sway + wayvnc + the noVNC viewer page

    src/cli/       the entry point and its two subcommands.
      Cli.res        argument parsing, on `node:util.parseArgs`
      Main.res       `serve`: the ten tools, and the MCP server behind them
      Stop.res       `stop`: the one destructive thing, and the refusal guarding it

    src/runtime/   other people's APIs, bound thinly. Nothing here is Passenger's.
      Fs Proc Posix Sqlite Timers WebSocket Node   what the BCL used to supply
      Http                                         fetch, bound once
      Mcp Pw                                       the SDK and Playwright
      Poll                                         waiting, and async find

**Never open a session by hand.** `Session.use` is `await using` from the C#
side, which ReScript has no keyword for: it attaches, runs the body, and detaches
on every exit including a throw. Before it existed, a `script` naming a tab the
lane did not own leaked the attach -- `pageFor` refused, the refusal travelled
past the `dispose` at the bottom, and the connection stayed open. Measured at
3 -> 10 connections to Chrome over five failed calls.

Two naming rules, both of them scar tissue. Every wire spelling is `<type>ToString`
-- `Errors.codeToString`, `Models.kindToString` -- because those six functions had
four conventions between them and one of them (`Errors.value`) was C#'s
extension-method name carried over whole. And `NestedSessions` keeps the word
`Nested`: `Session`, singular and next door, is the Playwright attach, and the
two were one letter apart until it bit.

Two placements are worth the sentence, because the obvious reading of each is
the other one.

`Geometry.res` is shell even though the half a test reaches -- `number` and
`firstBlock`, the two parsers a scale is discovered through -- is pure. The
module spawns `wlr-randr` and `wayland-info` for its own purposes, and a
directory that says "no subprocess" has to mean it. The parsers stay at the top
of the file where the tests find them.

`Script.res` is core even though it imports `node:vm` and hands a caller `fs`.
It touches no browser, no network and no disk *of its own*: what it does with
those bindings is pass them through to somebody else's code, and every decision
it makes -- what a line number is, what may cross back -- is a function of its
arguments. Its own header says "functional core, almost", which is the honest
hedge and is why it is worth reading before changing.

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
  tool (046). Adding a second way to do something already reachable through `script` needs a
  ticket's worth of justification.
- **This runs on the user's own machine, and the script door is not a sandbox.** One process
  on their laptop, their agent, their logged-in Chrome. Ticket 074 rests the design on that
  and deletes the two rules that pretended otherwise: a caller's source now runs in *this*
  context with node's own globals in scope, and the per-operation timeout is optional and
  unbounded. `Script.res` had said "deliberately not a sandbox, and not pretending to be one"
  for as long as the allowlist existed, which is the point -- a list that stops an accident
  but not an intent costs a caller with a legitimate need and buys nothing. Two things that
  look like restrictions survive because they are not: `console` is rebuilt onto stderr
  (stdout is the JSON-RPC transport, so this is protocol correctness), and `fetch`, while now
  in scope, is still the wrong answer -- it goes around the browser and therefore around the
  session, which is what ticket 046 was actually about. Do not re-add a wall here without a
  ticket that first says who is on the other side of it.
- **What crosses that door is JavaScript, and what comes back is JSON.** `Script.crossable`
  refuses only what is not a JSON document -- a cycle, a BigInt. It does *not* refuse a live Playwright handle, and the
  comment there says why the C# rule that did was an inheritance rather than a fact about this
  runtime: Playwright's JavaScript client ships `toJSON`, so a returned handle is 64 bytes
  that name themselves, and a rule that guessed at one would sooner refuse a site's own JSON.
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
