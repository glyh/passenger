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

*Updated by [Drop ICU](022-drop-icu.md).* Half of that motive is gone: there
is no PyICU any more, so "dotnet carries ICU in the BCL" argues for nothing,
and the Python side has no native dependency left to compile against a host
library. What survives is the overlay -- two of six dependencies still missing
or stale in nixpkgs -- which is a smaller claim than the one recorded above.
Weigh the port on the remaining measurements, not on packaging pain that has
already been removed.

**Extraction is decided elsewhere, and now is.** [Whether dom alone is
enough](025-whether-dom-alone-is-enough.md) asked, in Python, whether
`article` comes out. It does not: `dom` alone is not enough, on a comment
thread inside the content wrapper that no root rule reaches. So this port
carries an extraction problem, and the second phase below is live work.

**Porting trafilatura is live work, not a fallback, and it has fired.**
[025](025-whether-dom-alone-is-enough.md) closed on `article` staying, so this
is no longer conditional: the extraction core goes to C# too -- about 5,500
reachable lines of trafilatura (`core`, `main_extractor`, `xml`, `xpaths`,
`htmlprocessing`, `utils`, `settings`, `baseline`, `external`,
`readability_lxml`, out of 8,877 total), plus justext, plus an
XPath-capable DOM library standing in for lxml. Roughly twice the size of
the program it serves. That was first priced as a deterrent and it is not
one: on a hobby project a large clean port is the appealing part.
Correctness would be checkable against trafilatura's own published
evaluation rather than by taste. Before pricing our own, check whether a
.NET port already exists.

This phase's *shape* is now in dispute, and in the direction of being
smaller. [One extractor instead of
two](029-one-extractor-instead-of-two.md) proposes reimplementing rather
than porting, strong enough that `article` and `dom` collapse into one
mode -- and observes that a DOM-native algorithm has to run where the DOM
is, which would remove the XPath library and most of the 5,500 lines
along with it. That ticket *was* blocked on this one, since it presupposes
the port happens at all; the price recorded above is the upper bound. **That
edge was cut on 2026-08-24**, once the measurements showed extraction to be the
only remaining cost of any size: this ticket cannot be priced until 029's shape
is known, and 029's own instruction is to establish it in Python before any C#
is written. The dependency ran the wrong way.

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

*Measurements 1 and 2 are made.* See [the port
measurements](../assets/023-port-measurements-findings.md). Neither killed the
port, which was the cheap outcome they were run for.

**1 is answered, and the premise below is wrong.** patchright-dotnet does not
reimplement the evasions: it patches `microsoft/playwright-dotnet` at build
time and repoints the driver download at `patchright-core` on npm -- the same
tarball the Python package ships, at the same version this machine is running
(1.62.1 both sides). Parity is structural. What the author does own is the
binding patch and the release plumbing, and the version seam is real: the .NET
release tracks *playwright-dotnet* while the driver tracks *patchright*, so
there are windows where no matching driver exists. Bus factor is one. The
surface we need is present on inspection, not on a run. `BUGS.md` is worth
reading first: nothing we use is on it except `innerText` atomicity, which
`extract.py:121` relies on as the walker's fallback.

**2 is answered, and nothing is lost.** The SDK left preview -- 2.0 GA in July
2026, v2.2.0 now. stdio is one line; schemas generate from the method signature
via `AIFunctionFactory`, so no hand-written JSON; typed binding does *not*
degrade into `JsonNode`. This ticket briefly recorded a regression here -- that
bounds would not reach the schema -- and it was wrong, grepped rather than
tested. `[Range(0, 30000)]` emits the same `minimum` / `maximum` that
`Field(ge=0, le=30000)` does; the two schemas are equivalent down to the key
names. The whole contract carries: types, prose, defaults, bounds.

**3 is made, and found no blocker either.** Three tasks, both languages, all six
snippets written and checksummed before any was run: 3/3 each side, identical
output, on a throwaway Chrome and a local fixture. The mechanical differences --
`await` everywhere, an explicit type argument on `EvalOnSelectorAllAsync<T>` --
are not what breaks a first try. The failure paths differ more than the happy
ones: C# reports compile errors with a column *and before the browser is
touched*, gives no runtime line number until you use
`WithEmitDebugInformation` + `WithFilePath` + the `Stream` overload of
`CSharpScript.Create` (the `string` overload fails `CS8055`), and lets a live
`Locator` return unchallenged -- though `crossable` was thirty hand-written
lines on this side too. The async rewrite of the browser half remains
**unmeasured**.

**The async rewrite is measured too, and it was the smallest surprise here.**
`targets.py` entire and `browser.Session` with 012's recovery were ported,
compiled, and run against a wedged Chrome: same failure, same message, same
detail line as the Python. A transliteration with four exceptions -- the context
manager becomes an `OpenAsync` factory plus `IAsyncDisposable`, `raise ... from`
needs the inner exception passed by hand, the hand-rolled websocket deadline
collapses into one `CancellationTokenSource` and reads *better* than the
original, and `Target` maps onto a record with `[JsonPropertyName]`. Still
untried: `service.py`, and async virality reaching the CLI's entry points.

Porting it also found a bug in the original, filed as [a tab waiting on a server
that never answers](042-attach-hangs-on-pending-navigation.md) -- not C#'s
doing, but rebuilding a mechanism is what made its assumption visible.

**A fifth, added when the language was raised as F#.** Everything above
carries: Patchright .NET and the MCP SDK are .NET libraries, and an F# `Fetch`
with `[<Optional; DefaultParameterValue>]` and `[<Range>]` generates a schema
identical to the C# one and to today's Python door. What F# adds that neither
Python nor C# has is [Fable](https://github.com/fable-compiler/Fable), which
compiles it to JavaScript -- so `walker.js` can be written in the same language
as the rest of the tool and still run *in the page*, where `innerText` and
`checkVisibility()` live. Measured rather than assumed: all 165 lines ported to
F#, compiled, bundled, injected at `extract._DOM_JS`, and the repo's own walker
suite passes 13/13 against it -- with a sabotaged bundle failing 13/13, since
[034](034-broken-walker-passes-its-tests.md) is that exact trap. The cost is
43 KB bundled against 8 KB hand-written, almost all of it `fable-library`
because the port used F# `Set`, `Map` and `list`; JS-native structures would cut
most of that, untested. Packaging is the unmeasured part -- Fable, node and
esbuild joining a nix flake whose whole history is packaging pain.

**So all five are in, and none of them says no.** What is left is not a
measurement. The packaging motive was removed by 022, the remaining cost is
overwhelmingly the extraction port, and no regression was identified once the
bounds claim was tested rather than grepped. Whether that is worth a hobby project's evenings is the
developer's call, and it is the only thing between this ticket and closed.

The three as originally written follow, unedited.

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
