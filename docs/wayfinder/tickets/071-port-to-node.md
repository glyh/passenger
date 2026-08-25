---
id: 071
title: Port the server to Node, in plain JavaScript
labels: [wayfinder:research]
status: open
assignee:
blocked_by: []
---

## Question

`Passenger.Mcp` is C# because the door was C#, and the door was C# because
[053](053-delete-the-python-door.md) left it standing.
[069](069-powershell-instead-of-csharp.md) asked whether the *script* language
should change and turned up something larger: what a model writes well is not
a language but a language paired with a library, and the pair it knows best here -- Playwright's own JavaScript API
-- is already in this build, unused as an API.

**Measured today**, from the bundled driver against the Chrome the C# side is
currently driving, with nothing added to the closure:

    contexts: 1 pages: 1
     url: chrome://new-tab-page/ | title: New Tab

That is `patchright-core` 1.62.1 (`.playwright/package/index.mjs`) doing
`chromium.connectOverCDP('http://127.0.0.1:9222')` under the bundled
`node v24.19.0`. The JS Playwright ships here already, because the .NET
binding is a client of it over a pipe.

The owner's call, recorded so a later session does not re-litigate it:
**plain JavaScript, not TypeScript.** The reason given is the type system.

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
  `TreatWarningsAsErrors` is deliberate. Plain JS cannot replace that in kind
  -- and TypeScript, which could, is ruled out above. What can stand in is
  weaker and should be chosen knowingly: an `assertNever`-style default that
  throws at runtime, `Object.freeze` for the frozen records, and tests carrying
  the weight the compiler carries now. **Decide this before starting, not
  halfway through.** If the answer is "the tests can carry it", say so in this
  ticket first.
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
