---
id: 023
title: Whether this moves to C#
labels: [wayfinder:research]
status: open
assignee:
blocked_by: []
---

## Question

Whether the whole tool -- CLI, MCP server, browser control, extraction,
compositor management -- is rewritten in C#, and what the port would
actually cost. Two things make it askable now rather than hypothetical:

- **[patchright-dotnet](https://github.com/DevEnterpriseSoftware/patchright-dotnet/)**
  -- a patched `Microsoft.Playwright`, the same idea as the patchright
  this project already depends on.
- **[modelcontextprotocol/csharp-sdk](https://github.com/modelcontextprotocol/csharp-sdk)**
  -- an official MCP SDK, so the server half has a first-party answer.

The Python side is 2,970 lines across 22 modules, so the port is small
enough to be real. That is exactly why it should be measured before it is
started: a rewrite of something this size is a weekend, and a rewrite of
something this size that discovers a hole in week two is a fork of the
project.

**The motive is unstated.** Nobody has written down what the rewrite is
*for* -- static typing beyond what strict mypy already gives, a
single-file deployment with no interpreter, the native-dependency pain
that put the Python side in nix, or simply preference. The answer to this
ticket is worth little until that is on paper, because it decides which
of the costs below are acceptable and which are disqualifying. Start
there.

### What to measure

1. **patchright-dotnet's parity, and its cadence.** It is a third-party
   fork by a different author from the Python patchright this project
   runs. Establish: does it carry the same evasions (the CDP `Runtime`
   suppression that is the whole point), does it track upstream Playwright
   and upstream patchright on a schedule anyone can rely on, and does it
   expose the specific surface already load-bearing here --
   `connect_over_cdp` against a Chrome this tool launched itself,
   `page.request.get` (relied on in [Content that lives in
   pictures](014-content-that-lives-in-pictures.md)), and
   `locator.screenshot()`. A stealth fork that lags upstream by a version
   is a fingerprint, by the same argument that keeps Chrome unpinned in
   `flake.nix`.

2. **The MCP SDK against the seven tools.** [How thin can this layer
   get](020-how-thin-can-this-layer-get.md) settled the surface at seven;
   check each one lands. The specific things to look for are stdio
   transport, tool schemas generated from records rather than hand-written
   JSON, and whether the pydantic-shaped discipline this codebase runs on
   -- parse at every boundary, no raw dicts downstream -- survives the
   translation to `System.Text.Json` with source generators, or degrades
   into `JsonNode` at the door.

3. **Extraction, which is the hole.** `article` mode is trafilatura, and
   there is no .NET trafilatura. The readability-family ports that do
   exist (SmartReader and friends) are the *class of extractor* that
   [Whether defuddle belongs alongside
   trafilatura](009-defuddle-as-a-mode.md) already measured and found
   worse, and [A listing clears the yield
   floor](011-listing-clears-the-yield-floor.md) turned on trafilatura's
   particular judgement about what counts as boilerplate. So the options
   are: accept a measurably worse `article`, keep a Python sidecar for
   one function (which gives up the interpreter-free deployment that may
   be the whole motive), or port the judgement. Measure the first against
   the same pages 009 used before assuming any of them. `dom` mode ports
   cleanly -- it is a JavaScript string evaluated in the page, and does
   not care what language sent it.

4. **`script`, and what the agent has to write.** [The passthrough
   tool](013-the-passthrough-tool.md) runs *caller-supplied Python* with
   `page` and `read(page)` in scope. C# has no `exec`: the equivalent is
   Roslyn scripting, which means compiling a snippet per call, a
   references/imports set to maintain, and a slower first call. Harder
   than the mechanics, and probably the real question in this ticket:
   the caller is an LLM, and it writes Playwright-Python far more fluently
   than it writes Playwright-C#. If the central door gets more expensive
   for the only party that uses it, that outweighs a lot of typing wins.
   Measure it -- have an agent drive the same three tasks through both.

5. **Packaging, which cuts both ways.** `buildDotnetModule` and a NuGet
   lock replace the interpreter and `nix/python-overlay.nix`; the overlay
   exists only because two of seven Python dependencies are missing or
   stale in nixpkgs, and that specific pain goes away. Note also that
   .NET carries ICU in the BCL, so `count_words` would be free again --
   which does *not* reopen [Drop ICU](022-drop-icu.md), since 022's
   argument is that nothing decides with the number any more, not that
   the dependency is expensive.

6. **What does not move at all.** cage, wayvnc, wlr-randr and
   wayland-info are subprocesses and stay subprocesses; the noVNC page
   and the small web server behind it are HTTP and JavaScript. The
   session-record and pid-scoped teardown logic is process bookkeeping
   that translates directly. Roughly, `present.py`, `launch.py`,
   `geometry.py`, `session.py` and `webserve.py` -- call it 800 lines --
   are a transliteration, not a design problem.

### What the answer looks like

A markdown asset that says go or no-go with the measurements attached,
not an impression. If it is go, it should also say *when*: [Remove auto
mode](021-remove-auto-mode.md) and [Drop ICU](022-drop-icu.md) are both
open and both remove things, and porting code that is on its way out is
the one clearly wrong order.
