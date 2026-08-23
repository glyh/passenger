---
id: 023
title: Whether this moves to C#
labels: [wayfinder:research]
status: open
assignee: lyh (via Claude)
blocked_by: []
---

## Question

Whether the whole tool -- CLI, MCP server, browser control, extraction,
compositor management -- is rewritten in C#. Two things make it askable
rather than hypothetical:

- **[patchright-dotnet](https://github.com/DevEnterpriseSoftware/patchright-dotnet/)**
  -- a patched `Microsoft.Playwright`, the same idea as the patchright
  this project already depends on.
- **[modelcontextprotocol/csharp-sdk](https://github.com/modelcontextprotocol/csharp-sdk)**
  -- an official MCP SDK, so the server half has a first-party answer.

The Python side is 2,970 lines across 22 modules, so the port is small
enough to be real.

## Settled by grilling

Recorded here so they are not re-litigated. What remains open is below.

**The motive is maintainability, and it is a hobby project.** Chiefly
packaging: PyICU compiling against the host's libicu is what moved this
project to nix at all, and two of seven Python dependencies are missing or
stale in nixpkgs, which is why `nix/python-overlay.nix` exists. `dotnet`
carries ICU in the BCL and NuGet needs no overlay. The rest is preference,
which is a sufficient reason on a project with one developer and no users
to answer to. Type safety is *not* a motive: strict mypy with
`warn_unreachable` and frozen pydantic models parsed at every boundary is
a stricter contract than the C# port would get for free, and item 2 below
is about not losing it.

**Extraction is decided elsewhere.** [Whether dom alone is
enough](025-whether-dom-alone-is-enough.md) asks, in Python, whether
`article` comes out. It must be answered where both extractors can be run
against the same page.

**Porting trafilatura is live work, not a fallback.** If 024 says `dom`
alone is not enough, the extraction core goes to C# too -- about 5,500
reachable lines of trafilatura (`core`, `main_extractor`, `xml`, `xpaths`,
`htmlprocessing`, `utils`, `settings`, `baseline`, `external`,
`readability_lxml`, out of 8,877 total), plus justext, plus an
XPath-capable DOM library standing in for lxml. Roughly twice the size of
the program it serves. That was first priced as a deterrent and it is not
one: on a hobby project a large clean port is the appealing part.
Correctness would be checkable against trafilatura's own published
evaluation rather than by taste. Before pricing our own, check whether a
.NET port already exists.

**It lands alongside, not big-bang.** The C# implementation is built in
this repo next to the Python one, which keeps working and shipping
throughout -- `trunk` is committed to directly and this tool is in daily
use, so a big-bang leaves no working browser for however long the port
takes, which is how hobby ports die. Running both against the same URL is
also how the comparisons below get made.

**Python is deleted on daily use, not on a green test run.** [What the
test suite covers](001-testing-the-shells.md) records that the 25 tests
cover only the pure core; the shells that launch cage, wayvnc and Chrome
are the part that was silently broken before and are still untested. The
trigger is all seven tools working in C# against the page set the README
already measures, and the C# server as the daily driver for a couple of
weeks with the Python one still sitting there. Then one deletion commit.

**All Python-side work lands first.** [Remove auto
mode](021-remove-auto-mode.md), [Drop ICU](022-drop-icu.md) and
[Whether dom alone is enough](025-whether-dom-alone-is-enough.md) each
remove something, so waiting makes the port strictly smaller and spares
porting the same code twice.

## What is still open

Three measurements. This ticket is not blocked on the Python work -- the
measurements can be made now, and they are what decide whether the port is
attempted at all.

1. **patchright-dotnet's parity, and its cadence.** A third-party fork by
   a different author from the Python patchright this project runs.
   Establish: does it carry the same evasions (the `Runtime.enable`
   suppression that is the whole point), does it track upstream Playwright
   and upstream patchright on a schedule anyone can rely on, and does it
   expose the surface already load-bearing here -- `connect_over_cdp`
   against a Chrome this tool launched itself, `page.request.get` (relied
   on in [Content that lives in
   pictures](014-content-that-lives-in-pictures.md)), and
   `locator.screenshot()`. A stealth fork lagging upstream by a version is
   a fingerprint, by the same argument that keeps Chrome unpinned in
   `flake.nix`.

2. **The MCP SDK against the seven tools.** [How thin can this layer
   get](020-how-thin-can-this-layer-get.md) settled the surface at seven;
   check each one lands. Look for stdio transport, tool schemas generated
   from records rather than hand-written JSON, and whether parse-at-every-
   boundary survives into `System.Text.Json` with source generators or
   degrades into `JsonNode` at the door. Degrading it would forfeit the
   one thing the Python side is unambiguously good at.

3. **`script`, and what the agent has to write.** [The passthrough
   tool](013-the-passthrough-tool.md) made this the central door, and its
   caller is an LLM. Two costs, and only the first is mechanical:
   - **Playwright .NET has no sync API.** The Python side is built on
     `sync_playwright` throughout -- `browser.py`, `service.py`,
     `script.py`. .NET is `await page.GotoAsync(...)` with no sync
     alternative, so the browser half is an async rewrite rather than a
     transliteration, and every caller-supplied script becomes async C#.
   - **Fluency.** C# has no `exec`; the equivalent is Roslyn scripting,
     which handles the mechanics fine including the per-script line
     numbers 013 promised. The open risk is that
     `await page.Locator(...).ClickAsync()` in a compiled snippet is
     harder for an agent to get right first try than the Python
     equivalent. If the central door gets a worse hit rate that is a
     functional regression, and no amount of preference covers it.
     **Measure it**: three real tasks, both languages, first-try success.

## What does not move at all

cage, wayvnc, wlr-randr and wayland-info are subprocesses and stay
subprocesses; the noVNC page and the small web server behind it are HTTP
and JavaScript. The session record and pid-scoped teardown are process
bookkeeping that translates directly. Roughly `present.py`, `launch.py`,
`geometry.py`, `session.py` and `webserve.py` -- call it 800 lines -- are
a transliteration, not a design problem. `dom` extraction is a JavaScript
string evaluated in the page and does not care what language sent it.

## The answer

A markdown asset with the three measurements attached, and a go or no-go
that follows from them rather than from an impression.
