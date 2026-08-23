# Port measurements: patchright-dotnet and the MCP C# SDK

Asset for [Whether this moves to C#](../tickets/023-rewriting-into-csharp.md).
Measurements 1 and 2 of three. Measurement 3 -- `script` fluency -- is **not**
made here; it needs C# actually running against a page, and it was left until
the two desk measurements had a chance to kill the port cheaply. They did not.

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

`patchright-core` is the same npm tarball the Python package ships. Verified on
this machine: our nix environment holds `patchright-core` **1.62.1**, and
patchright-dotnet's latest release is **v1.62.1**. The evasions -- the
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

## Where this leaves the go/no-go

**Neither cheap measurement killed it.** Measurement 1 came back better than the
ticket feared: the evasions are shared, not reimplemented, so the biggest stated
risk is structural rather than a matter of trusting an author. Measurement 2
came back good with one named regression -- schema-visible bounds -- which is a
cost to price rather than a blocker.

So the cheap no-go did not arrive, and the decision now rests on **measurement
3**, which is the expensive one: three real tasks, both languages, first-try
success at writing `script` bodies, plus the fact that Playwright .NET has no
sync API and the browser half is therefore an async rewrite rather than a
transliteration. That was always the measurement most likely to decide it on
merit; it is now the only one left.
