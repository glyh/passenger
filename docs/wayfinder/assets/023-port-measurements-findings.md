# Port measurements: patchright-dotnet and the MCP C# SDK

Asset for [Whether this moves to C#](../tickets/023-rewriting-into-csharp.md).
All three measurements. 1 and 2 are desk research, run first so that either
could kill the port cheaply; neither did. 3 needed C# actually running against a
page, and was run after them.

Measured 2026-08-24 against patchright-dotnet at v1.62.1 and
modelcontextprotocol/csharp-sdk at v2.2.0.

## 1. patchright-dotnet: parity and cadence

**The premise the ticket was worried about is wrong, and in our favour.** It
recorded this as "a third-party fork by a different author from the Python
patchright", which implied someone reimplementing the evasions in .NET and
therefore drifting from them. That is not what it is.

The whole repository is five files. `build.ps1` clones
`microsoft/playwright-dotnet`, checks out the latest `release-X.Y` branch, and
runs `Patchright.cs` -- one 68 KB C# program -- over the source tree. The
decisive part is thirty lines of it (`Patchright.cs:218-234`), which rewrite the
driver download URL:

    https://registry.npmjs.org/playwright-core/-/playwright-core-{V}.tgz
    https://registry.npmjs.org/patchright-core/-/patchright-core-{V}.tgz

`patchright-core` is the same npm tarball the Python package ships -- and that
is now proved rather than inferred. The NuGet package was restored and its
bundled driver compared file by file against the one in our nix environment:

    diff -rq <python patchright driver>/package <nuget>/.playwright/package
    -> no differences, 109 files each side

Byte-identical, both at 1.62.1. The evasions -- the
`Runtime.enable` suppression through isolated execution contexts, the disabled
Console API, the command-flag tweaks, closed-shadow-root piercing -- live in
that Node driver, and both bindings speak to it over the same protocol. Parity
is structural rather than maintained, and "does it carry the same evasions" is
answered by construction.

What *is* this author's own work, and therefore what can rot: the binding
patch (the `isolatedContext` parameter added to `Evaluate*` and `EvalOnSelector*`),
the release plumbing, and keeping the patch applying to each new
`playwright-dotnet` release branch.

**Cadence is good but the version story has a seam.** Nine releases since
2025-12-01, tracking Playwright 1.56 through 1.62; v1.62.1 shipped two days
after the upstream driver's v1.62.1. The seam is that the .NET version is
driven by `microsoft/playwright-dotnet` releases -- `build.ps1` asks GitHub for
the latest one -- while the driver it wants comes from patchright, which
releases on its own clock. There is a commit for exactly this collision, *Fix
build error when compatible Patchright version not available* (2026-08-15), and
the README says deployments are "not automatic (yet)" and fixes "might take a
few days". So there are windows where a current playwright-dotnet has no
matching patchright-core. That is a real version of the fingerprint risk the
ticket raised, though a narrower one than a fork lagging on the evasions
themselves.

**Bus factor is the honest cost.** One maintainer, 46 stars, 7 forks, created
nine months ago, Apache 2.0. Upstream patchright has 4,148 stars and is the
thing everyone depends on; this is a thin, single-author layer over it. The
mitigation is that the layer is thin *and legible* -- 1,180 lines of patch
script -- so taking it over is a real option rather than a slogan.

**The surface we need lands, on inspection rather than on a run.**
`connect_over_cdp` -> `ConnectOverCDPAsync`, `page.request.get` ->
`IAPIRequestContext.GetAsync`, `locator.screenshot()` -> `ScreenshotAsync` are
plain Playwright .NET; since the bindings are Microsoft's own patched in place
and the driver is identical, there is no reason for them to be absent. Not
exercised, and it would be dishonest to call it verified.

**`BUGS.md` is worth reading before the port, not after.** A hundred lines of
Playwright tests that patchright knowingly fails. Cross-checked against what
this codebase actually uses:

- *Console events, `pageerror`, websocket routing, `expose_function`,
  init scripts* -- all listed as broken, none of them used here.
- *Atomic checks* -- `innerText should be atomic` is on the list, and
  `extract.py:121` uses `page.inner_text("body")` as the walker's fallback.
  Non-atomic means the read can interleave with page mutation. For a fallback
  on a settled page that is a small risk, but it is a real one and it is
  currently invisible.

## 2. The MCP C# SDK against the seven tools

**It has left preview.** The ticket was written against the 1.x line; the SDK
went 2.0 GA on 2026-07-28 and is at v2.2.0 as of 2026-08-13, "maintained in
collaboration with Microsoft", 4,489 stars, Apache 2.0. This is no longer a bet
on an SDK settling down.

**stdio is one line.** `builder.Services.AddMcpServer().WithStdioServerTransport()`,
first-party, in the quickstart sample. Nothing to find out.

**Schemas generate from the signature, which is what was asked.** Tools are
methods on a `[McpServerToolType]` class, marked `[McpServerTool]`, with
ordinary typed C# parameters carrying `[Description]`. The schema is built by
`AIFunctionFactory` / `AIJsonUtilities.CreateJsonSchema` from the CLR signature.
So no hand-written JSON, and the shape maps almost one-to-one onto what
`mcp_server.py` already writes with `Annotated[..., Field(description=...)]`.

**Parse-at-every-boundary does not degrade into `JsonNode`.** Arguments bind to
typed parameters; injected services arrive as parameters too. The feared
outcome -- a dictionary at the door and manual digging afterwards -- is not what
this SDK does.

**But the bounds are lost, and that is the one real regression.**
`RangeAttribute` appears **zero** times in the SDK: schema generation reflects
types and `[Description]`, not DataAnnotations. The MCP door currently ships six
bounded parameters, and every one of those bounds is *in the schema the calling
agent reads*:

| parameter | bound |
|---|---|
| `fetch.settle_ms` | 0 – 30000 |
| `fetch.wait_seconds` | 0 – 900 |
| `script.timeout_seconds` | 1 – 600 |
| `set_ttl.minutes` | 1 – 1440 |
| `show_browser.wait_seconds` | 0 – 900 |
| `show_browser.ttl_minutes` | 1 – 1440 |

In C# these become guard clauses in the method body: still enforced, no longer
*told*. An agent would learn the ceiling by being refused rather than by
reading. That is a downgrade of precisely the contract this map values, and the
port would have to buy it back by hand -- which is a finding [One description,
two doors](../tickets/026-one-description-two-doors.md) should hear, because a
declarative capability description would then have to carry bounds itself in
either language rather than lean on the framework.

**AOT is available and may be a packaging argument.** The samples set
`PublishAot=true` and the SDK is built with source-generated JSON contexts
throughout (`McpJsonUtilities`). A single self-contained native binary is
plausible, which is a genuine packaging win -- and worth noting because
[Drop ICU](../tickets/022-drop-icu.md) removed the packaging motive the port
was originally argued on.

## 3. `script`, and what the agent has to write

Measured 2026-08-24, after the two above. Setup: a throwaway headless Chrome on
its own profile and CDP port -- deliberately **not** the live session, because a
second CDP client initialises every open tab and there were twelve of them --
and a small local fixture page with a reveal-on-click block, a link list, and a
JS search form. A local fixture rather than a real site so that the thing being
measured is the snippet, not the site's flakiness.

**Protocol, because the experimenter is also the subject.** All six snippets
(three tasks, two languages) were written and checksummed *before* any of them
was run, so "first try" means first run rather than first success. The harness
on the Python side is the real `script.execute`; on the C# side it is Roslyn
`CSharpScript` with a `Globals` object binding `page`, which is the nearest
thing to 013's contract.

**Fluency: a tie. 3/3 both languages, byte-identical output.**

| task | Python | C# |
|---|---|---|
| click, wait for reveal, read it | pass | pass |
| filter links to `/item/`, absolute hrefs | pass | pass |
| fill, submit, wait out the placeholder, read results | pass | pass |

So the ticket's stated fear -- that a compiled snippet is harder to get right
first try -- did not reproduce on these three. The honest caveats are that three
tasks is a small n, that they were written by one author who knows both APIs,
and that a local fixture is the easy case. What it does establish is that the
*mechanical* differences (`await` on everything, an explicit type argument on
`EvalOnSelectorAllAsync<string[]>`) are not what breaks a first try.

**The failure paths are where the two doors actually differ**, and that is worth
more than the tie. Same three provoked faults each side:

| fault | Python (`script.py`, built) | C# (Roslyn, out of the box) |
|---|---|---|
| syntax error on line 2 | `invalid syntax (line 2)` + the offending line | `e1.csx(2,9): error CS1525` -- line **and column** |
| timeout on line 3 | `TimeoutError: ...` + `line 3: page.click("#nope", ...)` | `Timeout 900ms exceeded.` -- **no line at all** |
| returns a `Locator` | designed refusal naming what to return instead | reported `OK`, value `Locator@h1` |

Three readings, and none of them is "C# is worse":

1. **Compile errors are better in C#, and earlier.** Roslyn gives a column as
   well as a line, and it fails *before the browser is touched* -- Python's
   `compile()` does too, but the C# version catches a whole class of typos
   (wrong member name, wrong argument type) that Python only finds at runtime,
   mid-navigation, after the side effects have already happened.
2. **The runtime line number is recoverable, with a recipe worth writing down.**
   It needs `ScriptOptions.WithEmitDebugInformation(true)` *and* `WithFilePath`,
   *and* the `Stream` overload of `CSharpScript.Create` -- passing the source as
   a `string` fails with `CS8055: Cannot emit debug information for a source
   text without encoding`. With all three, the stack trace carries
   `snippets/e2.csx:line 3`. That cost one iteration to find here and would cost
   the port the same.
3. **Nothing crosses the boundary for free.** C# happily returned a live
   `Locator`. But `crossable` in `script.py` is thirty lines this project wrote
   itself -- the framework never gave it away either. Parity, not a regression;
   it just has to be built again.

**Unmeasured, and the ticket should keep saying so:** the async rewrite. Six
snippets and a fifty-line harness are not `browser.py`, `service.py` and
`script.py` going async. Playwright .NET having no sync API remains a real cost,
and this measurement did not touch it.

## Where this leaves the go/no-go

**Three measurements, no blocker.** The one that was meant to be most dangerous
came back safest: the driver is byte-identical, so the evasions are shared by
construction rather than by a third party's diligence. The SDK is GA, speaks
stdio in one line, and generates schemas from signatures. The central door is
not harder to write against, and its error reporting is better in one half and
buildable in the other.

**The costs that survive, all of them known before:**

- The extraction port -- trafilatura at ~5,500 reachable lines, or whatever
  [029](../tickets/029-one-extractor-instead-of-two.md) shrinks it to. Still the
  bulk of the work, and untouched by anything measured here.
- The async rewrite of the browser half, unmeasured.
- **One functional regression, newly identified**: six bounded parameters would
  keep their enforcement and lose their schema visibility.
- A single-maintainer dependency, mitigated by its being 1,180 legible lines.

**What this does not decide.** The measurements were run to find a blocker, and
there is none. Whether to spend a hobby project's evenings on a port whose
motive is now mostly preference -- the packaging half having been removed by
[022](../tickets/022-drop-icu.md) -- is not a measurement's call. That one is
the developer's, and it is the only thing still standing between this ticket and
closed.
