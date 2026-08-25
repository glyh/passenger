# The Node side, in ReScript

**This is not the port. It is the walking skeleton for
[071](../docs/wayfinder/tickets/071-port-to-node.md)**, which exists to prove
the four things that could have stopped the port before 5,800 lines were spent
finding out. All four are proved, against the Chrome that was already running:

    tools: script
    -> {"type":"ran","url":"https://www.chinanews.com.cn/",
        "returned":{"title":"中国新闻网_梳理天下新闻","emoji":"😀 腾冲","n":676}}
    -> {"type":"failed","error":"deliberate, line 2","line":2}

1. **The toolchain builds.** ReScript 12.3.1 from npm, `rescript build`,
   readable ES modules beside the sources.
2. **MCP speaks over stdio from ReScript.** The SDK's low-level `Server`, not
   `McpServer` -- the high-level one wants a zod schema per tool, and binding
   zod to restate a schema we already have as JSON buys nothing.
3. **Playwright attaches to the shared Chrome.** `connectOverCDP` against the
   daemon's `--remote-debugging-port`, a real page, a real title.
4. **A caller's JavaScript runs with honest line numbers.** `return` and
   top-level `await` both work, and a throw on line 2 is reported as line 2.

The fourth is the one worth reading `Node.res` for. A caller writes `return`,
which an ES module cannot do, so the source is wrapped in an async IIFE --
with **no newline before the body**, so line 1 stays line 1 in a stack trace.
That is the ticket 023 property, kept, without Roslyn and without the flat
~40ms compile the C# door pays.

Two bugs stop existing rather than being fixed, both about escaping:
`JSON.stringify` does not escape non-ASCII at all, so
[056](../docs/wayfinder/tickets/056-utf8-escape-regression.md) needs no
encoder and [070](../docs/wayfinder/tickets/070-astral-still-escapes.md)'s
emoji come back as emoji. The forked MCP SDK exists only to reach that
encoder, so it goes too.

## What is ported

The pure core, against the C# suite as the oracle -- `dotnet test` on both
`DetectTests` and `GeometryTests` is green today, and every case that still
describes something is here.

    npm test        # 63 passing

- `Errors.res` -- the codes, with `value` a switch the compiler checks.
- `Models.res` -- `signature`, `probe`, `blocker`, and `condition`.
- `Detect.res` -- the builtin table, `selectorsOf`, `matches`, `classify`.
- `Geometry.res` -- `number` and `firstBlock`, the two parsers a scale is
  discovered through, and `Scale` as an abstract type.
- `Lanes.res` -- the registry, all 26 C# cases, on `node:sqlite` rather than a
  package. `Config.res` and `Sqlite.res` come with it.
- `Targets.res` -- Chrome's targets over the CDP HTTP endpoint and a page's own
  socket, all 13 C# cases. `WebSocket.res` binds the runtime's own global, so
  the CDP socket costs no dependency either.

Three invariants stopped being tests and became shapes, which is the same move
`DetectTests.cs` records for ticket 021 ("structural rather than tested"):

- A signature carries one condition plus any others, so the condition-less
  signature `Validated()` threw on cannot be written.
- `Scale.t` is abstract with `make: float => option<t>`, so a zero or negative
  scale is not a value that exists rather than one that throws when checked.
- `Errors.value` is exhaustive by the compiler rather than by a `default` that
  throws.

One behaviour deliberately differs: `number(".")` answers `None` where C#
reached `double.Parse(".")` and would have thrown. No recorded output has
produced it, but nothing prevented it either.

## The one place the runtime changed a signature

`Lanes.chromeTabs` is async here where the C# interface was synchronous. That
side reached the same endpoints through `.GetAwaiter().GetResult()`; JavaScript
has no such move, so the promise travels and the four rules that ask Chrome
anything -- `occupied`, `closeTabs`, `sweep`, `counts` -- are async with it. The
rules are unchanged: what could not be blocked on is a property of the runtime,
not of what a lane means.

Checked against the live browser (`node live.mjs`, which points the state
directory at a temp path so it cannot touch a real registry):

    pages: 2 | first title: "腾冲温泉的相关微信公众号文章 – 搜狗微信搜索"
    socket looks right: true
    stuckSummary: none
    counts through the live seam: open=2 orphaned=0
    sweep collected: [] | orphan now holds 2

## What is deliberately missing

`Browser`, `NestedSessions`, `Probe`, `Handoff`, `Present`, `Launch`,
`Webserve`, `Script`'s crossing checks, and nine of the ten tools. `Main.res` is
still the skeleton: it opens a page directly and closes it, rather than going
through the registry that is now sitting there ported. Geometry's half that
spawns `wlr-randr` is not here either.

## Two seams, and why they are different

`Lanes.chrome` is a process boundary: what it swaps out is a browser on the
other end of an HTTP endpoint, which is the line tickets 001 and 034 drew.
`Lanes.clock` is not -- it is a clock a test can move, and it exists because
the C# suite bought the same coverage with `Thread.Sleep(1100)` twice. It is
2.2 seconds cheaper per run and does not turn a slow machine into a flake.

## Running it

    npm install
    npx rescript build
    node probe.mjs          # drives the server over stdio, needs Chrome on 9222
