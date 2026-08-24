---
id: 056
title: script's JSON reply escapes non-ASCII to \u, unlike the deleted Python door
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

Reported from the owner's notes vault, not from this repo: a session that has
been calling `script` against Chinese-language pages (xiaohongshu) for a while
noticed every non-ASCII character in `returned` comes back as `\uXXXX` --
`腾冲` rather than `腾冲` -- and asked why, having recalled seeing literal
UTF-8 "when this MCP is written in Python." [053](053-delete-the-python-door.md)
deleted that door on 2026-08-24. The C# door is now the only one, so if the two
ever differed here, deleting the fallback removed the means to compare them by
running both side by side -- 053's own "Not done" section named exactly this
risk in the abstract and did not check it.

### What is confirmed, not speculated

The current behavior is real and reproduces every time, not something to
re-verify: any `script` call that returns a string or object containing
non-ASCII text comes back through the MCP `returned` field fully `\u`-escaped.
This is consistent with `System.Text.Json`'s default `JavaScriptEncoder`,
which only leaves `UnicodeRanges.BasicLatin` unescaped and `\u`-escapes
everything else unless the caller supplies a broader encoder --
`Service.cs`/`Tools.cs` were not inspected line-by-line for this ticket, but
the observed behavior matches that default exactly, and nothing else in the
055-described envelope (`type`, `tab`, `returned`, `page`) offers another
explanation.

### What is not confirmed

Whether the Python door actually behaved differently is inference, not a
measurement, because there is nothing left to run it against. Two candidate
mechanisms, in order of how much they'd explain:

1. **Pydantic's Rust core.** If the Python MCP frontend serialized tool
   results through `pydantic_core` (directly or via the `mcp` SDK's own
   response handling), its default JSON serialization does not force ASCII
   escaping -- unlike stdlib `json.dumps(ensure_ascii=True)`, which is the
   default for a *bare* `json.dumps` call. Which path the deleted
   `mcp_server.py` actually took was not established for this ticket; the file
   is recoverable at `git show 26ee1b2^:passenger/mcp_server.py` (330 lines,
   confirmed to still exist in history) and the `mcp` SDK dependency pin is
   recoverable from the deleted `pyproject.toml` at the same revision, so this
   is checkable without guessing, by whoever picks this up.
2. **It never differed**, and the owner's memory of "literal characters" was
   this same escaped-but-decoded-by-the-client picture the whole time -- i.e.
   the terminal/client that rendered Python-door replies happened to decode
   `\u` sequences for display in a way the current client does not. This
   would make it a client-side or perception difference, not a server
   regression at all, and would mean this ticket's title is wrong. Worth
   ruling out before assuming (1).

### Why it might matter beyond cosmetics

The JSON is valid either way -- `你好` and `你好` decode to the same
string, and nothing downstream that parses `returned` as JSON breaks. Two
reasons it is still worth a decision rather than being closed as "working as
intended":

- **Context cost.** A `\u`-escaped CJK string is roughly 6x the bytes of the
  same string as literal UTF-8 (`\uXXXX` is 6 ASCII bytes per character vs.
  3 UTF-8 bytes per character for most CJK code points), and `script` replies
  are read directly into an agent's context. For a non-ASCII-heavy page read
  this is a real, measurable multiplier on every call, in the same spirit as
  [054](054-script-return-should-be-json.md)'s finding that an escaped
  single-line page read wastes context relative to writing it to disk.
- **Coupling with 052.** [052](052-walker-escapes-do-not-survive-transport.md)
  is about a *different* direction (input: pasted ` `/` ` regex
  literals decoding to real JS line terminators across the JSON tool-call
  *request* boundary) but the same class of hazard: whatever encoder choice
  this ticket lands on for the *reply* direction should be checked against
  it. `JavaScriptEncoder.UnsafeRelaxedJsonEscaping` (the obvious fix for the
  context-cost problem) still produces valid JSON and still escapes control
  characters and quotes correctly, so a `returned` string from it decodes to
  the same string either way -- but if any caller re-embeds a `returned`
  string verbatim into a *new* script's source (rather than treating it as
  inert text), a literal U+2028/U+2029 riding through unescaped would recreate
  052's hazard from a different content source. Worth a sentence in whichever
  skill this lands documented against, if it lands.

### To decide

1. **Switch to a broader `JavaScriptEncoder`** (e.g.
   `JavaScriptEncoder.UnsafeRelaxedJsonEscaping`, or a custom encoder over
   `UnicodeRanges.All`) for the `JsonSerializerOptions` used to write `Ran`
   and any other MCP reply. Fixes the context-cost problem directly. Needs a
   check against the 052 coupling above before shipping.
2. **Leave it as-is**, on the grounds that it's cosmetic and every caller
   already gets valid JSON. Weakest option given the measured context-cost
   multiplier above, but cheapest.
3. **First confirm which of the two "what is not confirmed" mechanisms is
   true**, since if it's (2) (perception, not a real difference), there is no
   regression to fix and this ticket should close on that finding alone,
   same shape as [054](054-script-return-should-be-json.md)'s "closed undone."

## Answer

Closed without a code change. The cause is confirmed, option 1 was attempted,
and it does not work -- not "fragile," actually blocked, twice over.

**The cause.** Confirmed by inspection, not just measurement-matching: no
`JsonSerializerOptions` set anywhere in this codebase, so `Ran` and every
other MCP reply go out through `ModelContextProtocol.Core`'s own
`McpJsonUtilities.DefaultOptions` -- `static readonly`, frozen with
`MakeReadOnly()` at type-init, `Encoder` unset (`JavaScriptEncoder.Default`).
That is the SDK's fixed choice, made once, for the process's lifetime.

**Option 1 doesn't reach the wire.** `AddMcpServer()`/`WithToolsFromAssembly()`
do accept a `JsonSerializerOptions`, and `[Range]`-style bounds plus
descriptions in `Tools.cs` prove that path is real for schema generation. But
it only shapes a tool's return *value* on its way to becoming a
string/JsonElement inside a `ContentBlock`. The JSON-RPC envelope that
actually goes over stdio -- the thing that wraps that content and is what a
caller's `returned` field measurement is against -- is written separately,
through the frozen `DefaultOptions` above, with no settable equivalent on
`McpServerOptions` or `WithStdioServerTransport()`. Measured, not assumed:
built this repo with `JavaScriptEncoder.UnsafeRelaxedJsonEscaping` passed to
`WithToolsFromAssembly`, drove the running server over its own stdio with a
raw JSON-RPC probe (`openLane` then `script` returning `"腾冲 hello"`), and
the wire bytes were unchanged -- `腾冲` either way. Tried both content
routes (`content[].text` and `UseStructuredContent = true`'s
`structuredContent`); same result. Reproduced again in a from-scratch minimal
MCP server outside this repo, a bare `string`-returning tool with no object
graph at all -- ruling out anything specific to `Ran`'s `[JsonDerivedType]`
polymorphism. This is a known gap, not a local mistake:
[modelcontextprotocol/csharp-sdk#795](https://github.com/modelcontextprotocol/csharp-sdk/issues/795),
open, unresolved, 2.2.0 is the latest published version and has no
workaround for it -- a maintainer's suggestion on a related issue
([#636](https://github.com/modelcontextprotocol/csharp-sdk/issues/636)) turns
out to fix a different failure (an exception serializing `Infinity`/`NaN`),
not this one; verified that distinction with the same isolated repro before
ruling it out. Left a comment on #795 with the repro and the specific gap
(`McpServerOptions`/the stdio transport have no `JsonSerializerOptions` hook)
in case it moves the ask.

**Reaching past the public API doesn't work either.** The natural next move --
reflect the private backing field and swap in a patched, unfrozen
`JsonSerializerOptions` before anything reads it -- fails at runtime, not just
in principle: .NET throws `FieldAccessException: Cannot set initonly static
field '<DefaultOptions>k__BackingField' after type ... is initialized` the
moment anything touches `McpJsonUtilities`, which happens on first access, so
there is no window before that to get in ahead of it. Going further than that
-- raw unsafe memory writes to the field's storage, bypassing the CLR's own
guard -- crosses from "hack" into genuine undefined behavior against a runtime
invariant (`readonly` statics are assumed constant post-init for JIT
optimization; writing around that can produce an incoherent view between
already-JITted and not-yet-JITted code, not just "wrong output"). Not
attempted for that reason.

**What this settles.** Item 3's question -- whether the deleted Python door
really differed, mechanism (1) or (2) -- is still open; nothing here bears on
it, and it no longer matters for closing this ticket. Whether or not it was
ever different, the context-cost problem the ticket names is real, confirmed,
and currently has no implementation inside this codebase's reach: it lives on
the far side of an SDK gap this repo doesn't control. Reopen if
`modelcontextprotocol/csharp-sdk` ships a `JsonSerializerOptions` hook on
`McpServerOptions` or the stdio transport -- #795 is where to watch.

## Reopened, and closed again: the SDK gap was patched (2026-08-24)

The condition this ticket named for reopening -- "if
`modelcontextprotocol/csharp-sdk` ships a `JsonSerializerOptions` hook on
`McpServerOptions` or the stdio transport" -- was met the same day, not by
upstream but by the owner, in a fork:
[glyh/csharp-sdk@utf8-wire-encoding](https://github.com/glyh/csharp-sdk/tree/utf8-wire-encoding),
two commits on top of 2.2.0. It adds exactly the hook the close above said was
missing, on both surfaces: `McpServerOptions.JsonSerializerOptions`, and a
`JsonSerializerOptions` init property on `StreamServerTransport` that
`StdioServerTransport` fills from the server options, so
`WithStdioServerTransport()` carries the choice through without a caller
touching the transport. Where the envelope used to be written with
`JsonContext.Default.JsonRpcMessage` unconditionally, it now resolves the
type info from those options and falls back to the source-generated contract
when they are null or are `DefaultOptions` itself -- so the default path is
unchanged and the frozen `DefaultOptions` is never mutated. Nothing in the
"reaching past the public API" paragraph above was needed or attempted; the
hack it rejected is now a property.

**What passenger does with it.** `Program.cs` sets, in the same
`AddMcpServer` callback that names the server:

```csharp
options.JsonSerializerOptions = new JsonSerializerOptions(McpJsonUtilities.DefaultOptions)
{
    Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
};
```

Derived from `DefaultOptions` rather than built fresh, because the options
still have to resolve `JsonRpcMessage`.

**How the dependency reaches the build.** A `PackageReference` cannot name a
git branch, so the flake builds the fork into real nupkgs and hands them to
restore as a local source. `flake.nix` takes the fork as a source-only input
pinned by commit, and an `mcpSdk` derivation packs `ModelContextProtocol` and
`ModelContextProtocol.Core` as `2.2.0-utf8wire.1` -- a prerelease tag, so it
can never collide with anything nuget.org publishes. Passenger names that
derivation in `projectReferences`, which is how nixpkgs puts local nupkgs into
the sandbox's offline restore source, and `Passenger.Mcp.csproj` asks for the
pinned version. `deps.json` loses its two `ModelContextProtocol` 2.2.0 entries
and gains nothing: the lockfile generator skips packages restored from a
directory source, so the fork is pinned by `flake.lock` and
`mcp-sdk-deps.json` instead.

Two things about that arrangement are not obvious and cost a build each:

- **A hand-run `dotnet` has no offline source.** The sandbox gets one for
  free; a `dotnet build` in the dev shell does not. `Directory.Build.props`
  appends `$(MCP_SDK_NUGET_SOURCE)` to `RestoreAdditionalProjectSources` when
  that variable is set, and the dev shell sets it to the built nupkg
  directory. Unset -- anywhere else -- the property does nothing.
- **nixpkgs rewrites packed nupkgs down to their `.nuspec`.** The fixup hooks
  unpack each nupkg into `share/nuget/packages`, delete `share/nuget/source`,
  and rebuild it holding metadata-only stubs, on the assumption that the only
  consumer is a nix build -- which gets the real contents from a fallback
  packages folder the hooks fill separately. Restoring from that by hand
  succeeds and produces a project that cannot see a single type in the
  package: 25 `CS0246`s, and a `project.assets.json` that names the right
  version. `createInstallableNugetSource = true` on the derivation keeps the
  contents (813 KB rather than a 2 KB stub).

**Measured, not assumed.** Same shape of probe as the close above: built
passenger through the flake (tests green), drove the built `Passenger.Mcp`
over its own stdio with a raw JSON-RPC probe, and read the wire bytes. A
`tools/call` naming a tool `腾冲` comes back

```
{"error":{"code":-32602,"message":"Unknown tool: '腾冲'"},"id":2,"jsonrpc":"2.0"}
```

-- literal UTF-8, three bytes per character, and zero `\u` sequences in the
whole reply. The dev-shell `dotnet build` is clean by the same commit. Note
what the probe is and is not: it is the JSON-RPC envelope, which is what this
ticket was about and what the close above proved unreachable, but it is an
*error message* rather than a `script` return -- driving a real `script` call
needs a browser, and none was attached. Nothing here re-measured the
context-cost multiplier on a real page read.

**Still open, deliberately.** Item 3 -- whether the deleted Python door ever
differed, mechanism (1) or (2) -- remains unanswered and now cannot be
answered; it no longer bears on anything. And the 052 coupling the "To decide"
section flagged is real and was accepted, not solved:
`UnsafeRelaxedJsonEscaping` passes U+2028/U+2029 through unescaped. The JSON
is still valid and stdio framing is unaffected, since neither character is a
JSON newline; the hazard is only a caller re-embedding a `returned` string
verbatim into new script source, which is 052's shape from a different
content source. `JavaScriptEncoder.Create(UnicodeRanges.All)` does not fix it
either -- it permits the same two characters, while spending bytes escaping
`<`, `>` and `&` -- so the choice was the relaxed encoder plus a sentence in
the `using-passenger` skill, which is not yet written.
