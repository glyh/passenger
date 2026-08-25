---
id: 071
title: Port the server to Node, in ReScript
labels: [wayfinder:research]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

`Passenger.Mcp` is C# because the door was C#, and the door was C# because
[053](053-delete-the-python-door.md) left it standing.
[069](069-powershell-instead-of-csharp.md) asked whether the *script* language
should change and turned up something larger: what a model writes well is not
a language but a language paired with a library, and the pair it knows best
here -- Playwright's own JavaScript API -- is already in this build, unused
as an API.

**Measured today**, from the bundled driver against the Chrome the C# side is
currently driving, with nothing added to the closure:

    contexts: 1 pages: 1
     url: chrome://new-tab-page/ | title: New Tab

That is `patchright-core` 1.62.1 (`.playwright/package/index.mjs`) doing
`chromium.connectOverCDP('http://127.0.0.1:9222')` under the bundled
`node v24.19.0`. The JS Playwright ships here already, because the .NET
binding is a client of it over a pipe.

### Which language, given it is not TypeScript

Two language choices hide in this ticket and only one is open. **The caller's
script stays JavaScript** -- that is the entire point of the move, and no
server language changes it. What the *server* is written in is the question.

The owner's call, recorded so a later session does not re-litigate it:
**not TypeScript, because the type system is unsound** -- `any` leaks and the
compiler will lie to you. That rules out the cheap answer of JSDoc annotations
checked by `tsc --checkJs` as well, since it inherits the same system, and it
points at a *sound* language compiling to JS rather than at plain JS.

Which matters more here than it first looks, because it directly answers the
type-system cost below. This repo is functional core, imperative shell: the
core (`Detect`, `Models`, `Errors`, `Geometry`) has **no JS interop at all**,
and it is exactly where an unhandled case must stay a compile error. The
shell is where the bindings tax falls and is the half that needs the types
least. A sound language buys the most where it costs the least.

Every candidate pays that same bindings tax -- nobody has written bindings for
Playwright or the MCP SDK in any of them -- so it does not discriminate
between them. The type system and how much of it a model can write do. So
does who would still be maintaining it in five years: none of the three has a
company behind it, and the question is what survives if the maintainers stop
-- a language with an owner and other backends, or nothing.

**Decided: ReScript.** The owner's call, with the reasoning kept so a later
session does not reopen it rather than because it was close.

*Why it won.* The binding tax turned out not to discriminate at all -- checked
2026-08-26, there are no Playwright bindings on GitHub or npm for ReScript,
Melange or anything else, and ReScript needs `external` declarations exactly
as Melange does; same BuckleScript ancestry, same mechanism, `@send`/`@module`
against `[@mel.send]`/`[@mel.module]`. What does discriminate is how the
bindings *feel* against an API where every call is a promise. ReScript has had
real `async`/`await` since 10.1 and is uncurried by default; Melange refuses
both on purpose, to avoid widening the gap with upstream OCaml, and gives you
`let*` over `Js.Promise` instead. That is workable but it is not free here:
OCaml's `try ... with` cannot cross a `let*`, so a rejection has to be caught
with `Js.Promise.catch` as an untyped value, and this shell has 48 `catch`
sites, 9 loops containing an await, and 27 delay/deadline/retry sites -- the
three shapes monadic binding handles worst.

*What is being accepted.* ReScript's ergonomics are bought by walking away
from OCaml compatibility, and that same trade is why ReScript code has no exit
if the project stops: its syntax and stdlib are its own, and v11 onward
dropped the compatibility that would have made Melange a fallback. Melange
would have kept that exit -- OCaml source stays valid OCaml, with
js_of_ocaml as a second backend -- at the cost of the promise ergonomics
above. Both readings are defensible; this one is chosen knowingly.

The maintainer numbers behind that risk, measured 2026-08-26: Hongbo Zhang,
who wrote BuckleScript and turned it into ReScript (8,637 commits), last
committed **November 2022** and has moved to MoonBit; Patrick Ecker last
committed October 2023. Of the last 100 commits, Christoph Knittel has 29 and
Cristiano Calcagno 25, everyone else in single digits. Against that: the
project ships steadily (523 commits in the last year, v12.3.1 on 2026-08-24),
which is twice Melange's rate, and Melange's own bus factor is *one*
(anmonteiro, 93 of the last 100), so "more maintained" was never Melange's
argument -- survivability was.

*Also rejected, with reasons:* F# via Fable (the earlier recommendation in
this ticket -- keeps the .NET family and gains real unions, but adds a second
toolchain and models are weak at Fable's interop attributes); OCaml via
Melange (above); js_of_ocaml (compiles bytecode, emits a runtime blob, built
to run OCaml in a browser rather than to live in an npm project -- worse at
the one thing this port is for); plain JS and TypeScript (the type system,
above); Gleam and PureScript (fluency near zero); Scala.js and Kotlin/JS (a
JVM in the build cancels the closure win); ClojureScript (dynamic, a worse
type position than C# is today).

*Consequences to plan for.* ReScript is not a top-level nixpkgs package, so
the toolchain arrives through npm and has to be packaged for a build that is
currently nix all the way down -- that is a real task in this port, not a
footnote. And the bindings, though only about fifteen Playwright members deep
(see below), are all new work in a language with less to copy from than the
JS ecosystem has.

### What the port would win

1. **The caller writes the API the model knows.** Four of the eleven bites in
   `writing-scripts.md` are C#'s and would simply cease to exist: the verbatim
   string around every JS snippet, the nested `await` that will not compile,
   local functions before the `return`, and the `JsonDocument`/`JsonSerializer`
   handling that [068](068-json-encoder-in-scope.md) closed on. A JS snippet
   stops being a string in another language and becomes the program.
2. **The fork goes away.** `Program.cs:54` says it outright -- reaching the
   envelope encoder "is the whole reason this repo builds a forked SDK". Node's
   `JSON.stringify` does not escape non-ASCII at all, so
   [056](056-utf8-escape-regression.md) and
   [070](070-astral-still-escapes.md) both stop being problems that can exist,
   along with `mcp-sdk-deps.json`, the `MCP_SDK_NUGET_SOURCE` dance in
   `Directory.Build.props`, and the version pin that has to match by hand.
3. **The closure loses the .NET runtime.** 78.3 MiB by
   [060](060-trim-the-closure.md)'s own table, on a build whose Node is already
   there and non-negotiable.
4. **`Lanes`' SQLite has a builtin replacement.** `node:sqlite` is in the
   bundled Node 24, so the `Microsoft.Data.Sqlite` dependency does not need a
   replacement package.
5. **One less hop.** Today a Playwright call crosses C# -> pipe -> Node ->
   CDP. Two of those disappear.

### What it would cost

- **~5,800 lines of `src` and ~1,700 of tests**, re-done. `Geometry`,
  `Detect`, `Errors` and `Models` are pure and port mechanically;
  `NestedSessions` (605), `Lanes` (595) and `Browser` (539) are the ones that
  carry the hard-won behaviour, and every one of their comments is load-bearing
  history that has to travel with them rather than be re-derived.
- **The type system, and this is the real price.** `CLAUDE.md` names it as
  load-bearing: blockers are a discriminated union "so an unhandled case in a
  `switch` expression is a compile error", nullable reference types are on, and
  `TreatWarningsAsErrors` is deliberate. This is a cost only if the server is
  written in JavaScript or TypeScript -- a sound compile-to-JS language keeps
  the guarantee, and F# strengthens it. It is listed here because it is the
  thing to protect, and because a port that quietly ends up in plain JS for
  expedience has given away the property this codebase is built on.
- **Script line numbers.** [023](023-rewriting-into-csharp.md)
  bought a runtime line number for a caller's script with a file path and
  emitted debug information. The Node equivalent is parsing a stack trace from
  a `vm` context, and it has to be at least as good or every failure gets
  worse to fix.
- **`Crossable` gets harder, not easier.** `Script.cs:183` refuses a live
  Playwright handle by type, and the comment records why it is a rule rather
  than a list -- `IAPIResponse` was not in the list and serialised the driver's
  internals as if they were an answer. JS has no type to test; it would be
  duck-typing against Playwright's own classes, which is exactly the shape that
  failed before.
- **Patchright's patching.** The stealth fork's JS package is what ships, so
  the API is there, but that it behaves identically when driven directly
  instead of through the .NET binding is an assumption until measured. This is
  the whole point of the tool, so measure it early -- against a real wall, not
  a smoke test.
- **The bindings, and they are smaller than they sound.** Counted against the
  current shell, it touches about fifteen Playwright members -- `Pages`,
  `Contexts`, `Url`, `NewPage`, `Goto`, `Title`, `InnerText`, `Close`, the two
  CDP-session calls, `Send`, `TargetId`, `PageFor`. Not the API surface, a
  corner of it, because **the caller's script is raw JavaScript calling
  Playwright directly** and needs no bindings at all. The MCP SDK is the other
  binding job. Both can start behind `%raw` and gain types where they pay.
- **Catch rejections at the binding, not at the call site.** Whatever the
  language, wrap each binding to return a `result` rather than letting a JS
  rejection travel: `Service.cs:93` already says a failure here is "an outcome
  rather than an exception, for the same reason `blocked` is one". Doing that
  once per binding is what keeps the 48 `catch` sites from being ported one by
  one.
- **The nix side changes wholesale**: `buildDotnetModule` and two lockfiles
  out, a Node build in, and `nix bundle` re-checked.

### How it would be sequenced

Not a big bang, and not a strangler either: the two doors cannot both exist
under ticket 004. The shape that fits this repo is to port the pure core first
(`Detect`, `Geometry`, `Errors`, `Models`) with the existing C# test suite as
the oracle -- same inputs, same outputs, checked case by case -- and only then
the shell, with the C# server still running until the JS one passes the same
acceptance set. Which acceptance set is exactly the gap
[069](069-powershell-instead-of-csharp.md) records: there is no scripting-task
benchmark in this repo yet, and this port is a much better reason to build one
than a language comparison was.

### What this does to 069

If this goes ahead, 069 is moot -- PowerShell was the cheaper answer to a
question this supersedes. Leave it open until this one is decided, then close
it against whichever way this goes.

## What was built

The port is done and lives in `node/`. Every module has crossed, all ten tools
answer over stdio, and the C# suite was the oracle throughout: `dotnet test`
107/107 and `npm test` 117/117 on the same day. `node/README.md` carries the
detail; this is what the ticket needs to know.

**The four risks were measured before the work, and three of them dissolved.**

- *Script line numbers.* Better than the C# door, not merely as good. A caller
  writes `return`, which an ES module cannot do, so the source is wrapped in an
  async IIFE **with no newline before the body** -- so line 1 stays line 1 in
  the stack trace, and both `return` and top-level `await` work. No Roslyn, and
  none of the flat ~40ms per compile.
- *`Crossable` gets harder.* It did, and the answer measured better than the
  guess. There is no type to test, so the rule was measured off live objects
  instead: every Playwright handle is a ChannelOwner (a string `_guid`), a
  `Locator`/`APIResponse` (a string `_apiName`, no `_guid`), or something like
  `Keyboard` that is neither but holds one in a field. Three tests, the third
  one level deep. Property reads rather than `instanceof`, which is
  load-bearing -- a vm context is its own realm. Pinned twice: the unit suite
  against stand-ins carrying the measured shapes, and `live-session.mjs`
  against eleven real handles.
- *The bindings.* As small as counted. Playwright is ~20 members, the MCP SDK
  is six externals, and neither needed `%raw` to start.
- *The type system.* Kept, and in three places strengthened past what C# could
  express -- a signature that carries one condition plus any others cannot be
  written without one, `Scale.t` is abstract so a non-positive scale is not a
  value, and `Errors.value` is exhaustive by the compiler rather than by a
  `default` that throws.

**Three signatures the runtime changed, all of them shell, none of them rules.**
`Lanes.chromeTabs` is async where the C# interface reached the same endpoints
through `.GetAwaiter().GetResult()`; `Session` has no driver process to restart,
so a wedged attach is released by the deadline Playwright takes rather than by
disposing a driver; and `Launch.plan` is async because the VNC port is claimed
by scanning for a free one. Two got *shorter*: `Posix.kill` is a binding rather
than a `DllImport`, and `Webserve`'s re-exec needs no special case for how the
binary was built.

**One bug the port found by running it.** Playwright .NET works out that a
string like `sels => ...` is a function; this client decides by `typeof`, so the
same string is evaluated as an expression, produces a function object in the
page, and comes back as `undefined` with nothing thrown. The probe then carried
no matched selectors and **every page read as clean** -- a wall reported as an
open road, which is the shape ticket 042 removed from the attach message.
`Probe.match` is a real function now.

## Answer

**Done.** The C# tree is deleted and the node tree is the repo: `src/*.res`,
`test/*_test.res`, `assets/`, and one entry point at `src/cli/Main.res.mjs`. Gone
with it: `Passenger.slnx`, `Directory.Build.props`, `deps.json`,
`mcp-sdk-deps.json`, the forked MCP SDK flake input, and the `MCP_SDK_NUGET_SOURCE`
dance the dev shell needed to find it.

### Packaging turned out easier than this ticket feared

The worry above was that ReScript is not in nixpkgs, so the toolchain arrives
through npm into a build that is nix all the way down. Measured: the compiler's
npm binaries are **statically linked** (`static-pie`, on `@rescript/linux-x64`),
so there is nothing to patchelf and `buildNpmPackage` runs `rescript build` in
the sandbox as it comes. `npmDepsHash` locks the tree the way `deps.json` did.

Two things had to be got right and both were found by running it, not reading:

- **Flakes ignore untracked files.** Half the sources were moved with `mv`
  rather than `git mv`, so the sandbox saw 11 files instead of 41 and the build
  failed with "The module or file Config can't be found" -- which reads like a
  `rescript.json` mistake and is not.
- **The compiler is a devDependency; its runtime is not.** They are separate npm
  packages, and `npm prune --omit=dev` took `@rescript/runtime` out with
  `rescript`, leaving a binary that could not start. It is a direct dependency
  now. What *can* go is that package's `lib/ocaml` -- 18 MiB of stdlib sources
  the compiler reads and the emitted JavaScript never imports.

### What it cost and what it bought, measured

    closure   657.8 MiB  ->  588.6 MiB      (-69.2, against the -78.3 predicted)
    src       5,968 lines of C#  ->  4,247 of ReScript
    tests     1,739 lines  ->  1,633, and 107 cases -> 116
    deps      2 NuGet lockfiles + a forked SDK  ->  package-lock.json

The suite runs inside `nix build` as it did before (`doCheck`), and the built
`result/bin/passenger` answers `tools/list` with all ten and `browserStatus`
against a live session.

### The four risks, and how they turned out

- *Script line numbers.* Better than the C# door, not merely as good. A caller
  writes `return`, which an ES module cannot do, so the source is wrapped in an
  async IIFE **with no newline before the body** -- so line 1 stays line 1 in the
  stack trace, and both `return` and top-level `await` work. No Roslyn, and none
  of the flat ~40ms per compile.
- *`Crossable` gets harder.* **It dissolved.** The first answer was a rule
  measured off live objects -- `_guid`, `_apiName`, or an object holding one --
  and the owner was right that it was a C# habit rather than a fact about this
  runtime. On that side `System.Text.Json` walked a handle's live object graph
  and emitted something large and answer-shaped, which is ticket 013's bug. Here
  Playwright ships `toJSON`: all eleven handle kinds serialise to 64-945 bytes
  and every one names itself (`_type`, `_apiName`), measured in
  `live-session.mjs`. Nobody mistakes that for their data -- and the rule could
  not be exact, so a site whose JSON carries a field called `_guid` would have
  had its data refused. The boundary now refuses only what is genuinely not a
  JSON document, a cycle or a BigInt, and the skill says what `_apiName` in a
  reply means.
- *The bindings.* As small as counted. Playwright is ~20 members, the MCP SDK is
  six externals, and neither needed `%raw` to start.
- *The type system.* Kept, and in three places strengthened past what C# could
  express -- a signature that carries one condition plus any others cannot be
  written without one, `Scale.t` is abstract so a non-positive scale is not a
  value, and `Errors.value` is exhaustive by the compiler rather than by a
  `default` that throws.

### Three signatures the runtime changed, all shell, none of them rules

`Lanes.chromeTabs` is async where the C# interface reached the same endpoints
through `.GetAwaiter().GetResult()`; `Session` has no driver process to restart,
so a wedged attach is released by the deadline Playwright takes rather than by
disposing a driver; and `Launch.plan` is async because the VNC port is claimed by
scanning for a free one. Two got *shorter*: `Posix.kill` is a binding rather than
a `DllImport`, and `Webserve`'s re-exec needs no special case for how the binary
was built.

### One bug the port found by running it

Playwright .NET works out that a string like `sels => ...` is a function; this
client decides by `typeof`, so the same string is evaluated as an expression,
produces a function object in the page, and comes back as `undefined` with
nothing thrown. The probe then carried no matched selectors and **every page read
as clean** -- a wall reported as an open road, which is the shape ticket 042
removed from the attach message. `Probe.match` is a real function now.

### What this does not settle

**Patchright.** Measured only as far as `connectOverCDP` against the running
Chrome, plus one real round of the owner's `passenger-xiaohongshu` skill: search
rendering, filter clicking, card extraction and a 14-note metadata batch all came
back clean, and the skill's own baselines held except that note HTML has grown
from ~40 KB to 94-155 KB. That it *behaves* identically against a real wall is
still an assumption, and it is the acceptance set [069](069-powershell-instead-of-csharp.md)
records as missing. Not a reason to keep two trees; a reason to build that set.
