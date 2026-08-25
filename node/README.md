# The Node side, in ReScript

**The port is complete: all ten tools, over stdio, against a real browser.**
This is [071](../docs/wayfinder/tickets/071-port-to-node.md), and it started as
a walking skeleton for four things that could have stopped it before 5,800
lines were spent finding out. All four held:

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

Everything, against the C# suite as the oracle: `dotnet test` is green at
107/107 today, and every case that still describes something is here.

    npm test        # 117 passing

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
- `Config.res` -- every `PASSENGER_*` variable, read once, each its own `ref` so
  a suite can point the state directory at a temp path.
- `Session.res` -- attaching Playwright to the running Chrome, the rescue when a
  wedged tab holds the attach open, and lane-scoped tabs (`page`, `pageFor`,
  `targetId`, `closeOthers`).
- `Script.res` -- the door's core, all 13 C# cases: compiling a caller's source,
  reporting a throw against their own line, and deciding what may cross back.
- `Probe.res` -- measuring a live page into the record `Detect` judges.
- `Service.res` -- the one orchestration, and the outcome unions. The C# side
  spelled those as a base record with a `type` discriminator and wrote out every
  JSON property name, because C# has no unions; here they are unions and the
  wire shape is written once, in `encode`, to the same bytes.
- `Sessions.res` -- the record that says which sway, wayvnc and viewer belong
  together, and the /proc predicates under it. All 14 C# cases, against real
  processes: `/bin/sh`, `sleep` and `trap`, no python.
- `Launch.res` -- the nested sway backend, the generated session script and
  config, and `which`. All 12 C# cases, plus one the port needs (below).
- `Webserve.res` -- the viewer's server and the path rule under it, all 8 C#
  cases. `Present.res`, `Notify.res` and `Handoff.res` come with it; Handoff's
  3 cases are here too.
- `Browser.res` -- the daemon lifecycle, and `Geometry`'s other half: the
  `wlr-randr` probe and the scale it applies.
- `Stop.res` -- the one verb a human types, and the refusal that guards it.
- `Main.res` -- all ten tools, over stdio, plus the two argv checks that run
  before the server: the viewer re-exec and `stop`.

Three invariants stopped being tests and became shapes, which is the same move
`DetectTests.cs` records for ticket 021 ("structural rather than tested"):

- A signature carries one condition plus any others, so the condition-less
  signature `Validated()` threw on cannot be written.
- `Scale.t` is abstract with `make: float => option<t>`, so a zero or negative
  scale is not a value that exists rather than one that throws when checked.
- `Errors.value` is exhaustive by the compiler rather than by a `default` that
  throws.

`Errors.res` grew the half the skeleton did not need: `detail`, and the named
constructors that fix the wording of a failure in one place. The C# side needed
a class hierarchy -- `DaemonException`, `ScriptException`, `TabNotFoundException`
-- so that a `catch` could name a family; here the code *is* the discriminator
and a `switch` on it is exhaustive, so the hierarchy collapses into one
exception carrying three fields.

One behaviour deliberately differs: `number(".")` answers `None` where C#
reached `double.Parse(".")` and would have thrown. No recorded output has
produced it, but nothing prevented it either.

## Where the runtime changed a signature

Three so far, and every one of them is the runtime rather than the design.

The first is `Lanes.chromeTabs`, async here where the C# interface was synchronous. That
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

The second is in `Session`: there is no driver process. .NET's Playwright talks
to a Node driver it spawns, so a wedged attach could be cleared by disposing the
driver and making a new one; here Playwright *is* the process, so
`RestartDriverAsync` has nothing to restart. What has to be released instead is
the abandoned attach itself, and the only handle on it is the deadline
Playwright takes -- which is worth passing here where ticket 012 measured it not
being honoured there, because in this runtime it is a `progress.race` in the
same process with cleanup that closes the CDP transport. That is a reading of
the library rather than a measurement against a wedged tab, so our own race
stays as the thing that guarantees the call returns.

The third is `Launch.plan`, async where the C# interface was synchronous. The
port a session advertises is claimed by scanning for a free one, and asking
whether a TCP port is taken has no synchronous form here. What is planned is
unchanged, down to the quoting.

Two things get *shorter* in this runtime, which is worth saying beside the
three that got longer. `Posix.kill` was a `DllImport` because .NET's
`Process.Kill` sends SIGKILL and only to a handle it owns; `process.kill` takes
the signal by name and any pid. And `Webserve`'s re-exec needs no special case
for how the binary was built -- `argv[0]` is the runtime and `argv[1]` is the
entry module, always, where the C# side had to tell a framework-dependent
`dotnet Passenger.Cli.dll` from a published apphost.

`Session` too is checked against the live browser (`node live-session.mjs`):

    isUp: true
    lane: 47672a094d0c0bac
    tab: B9FCA16A0ACF939770B9A70144C64CBA | owner: 47672a094d0c0bac
    pageFor returned the same tab: true
    blank tab reused: true
    pageFor a foreign tab: [TAB_NOT_FOUND] no tab deadbeef in lane 47672a...
      -- open in this lane: B9FCA16A0ACF939770B9A70144C64CBA
    detached; chrome still up: true

## What is still missing

Nothing of the tool itself. What is left is packaging and the decision the
ticket exists to make: the flake still builds the C# server, `nix run .` still
starts it, and nothing has been deleted. The two trees run side by side until
[071](../docs/wayfinder/tickets/071-port-to-node.md) closes.

One duplication comes with that. The four assets -- `session.sh`, `sway.conf`,
`ime.sh`, `viewer.html` -- exist in both trees, because the C# side embeds them
in its assembly and this side reads them off disk beside the compiled modules.
A thirteenth `Launch` case compares the two copies and fails on drift, and
skips where the sibling tree is absent, so it deletes itself when the C# tree
does.

## Two seams, and why they are different

`Lanes.chrome` is a process boundary: what it swaps out is a browser on the
other end of an HTTP endpoint, which is the line tickets 001 and 034 drew.
`Lanes.clock` is not -- it is a clock a test can move, and it exists because
the C# suite bought the same coverage with `Thread.Sleep(1100)` twice. It is
2.2 seconds cheaper per run and does not turn a slow machine into a flake.

## One bug the port found by running it

`Probe.match` is a real function where the C# side passed JavaScript as a
string. Playwright .NET works out that a string like `sels => ...` is a
function; this client decides by `typeof`, so the same string is evaluated as an
*expression*. That produces a function object in the page, which is not
serialisable, which comes back as `undefined` -- and nothing throws. The probe
then carries no matched selectors and every page reads as clean: a wall reported
as an open road, which is the exact shape ticket 042 removed from the attach
message. Found by driving the door, not by review, which is twice now for this
kind (ticket 049 was the other).

## Running it

    npm install
    npx rescript build
    node probe.mjs          # drives the server over stdio, needs Chrome on 9222
    node live-session.mjs   # Session and the handle rule, against a real browser
    node live-webserve.mjs  # the viewer server's routes, needs a real noVNC
    node live-handoff.mjs   # the whole handoff path, opening no window

`probe.mjs` opens a lane, runs a page, continues on the same tab, provokes each
of the three failures, and takes the lane away again:

    tools: script, openLane, setTtl, listTabs, closeTabs, closeAllTabs, destroyLane
    openLane -> ef8f9bfce4fea487
    script -> {"type":"ran","tab":"B912...","returned":{"title":"中国新闻网_梳理天下新闻",
               "emoji":"😀 腾冲","n":676},"page":null}
    script -> {"type":"failed","code":"SCRIPT_RAISED","error":"Error: deliberate, line 2",
               "where":"line 2: throw new Error('deliberate, line 2');"}
    script -> {"type":"failed","code":"SCRIPT_INVALID","error":"Unexpected token ';' (line 2)"}
    script -> {"type":"failed","code":"SCRIPT_RETURN_NOT_JSON",
               "error":"a Locator cannot cross the tool boundary"}
    script !! [TAB_NOT_FOUND] no tab B912... in lane 31b1... -- this lane has no tabs
    script !! [LANE_NOT_FOUND] no lane ef8f... -- it expired, or never existed

`live-handoff.mjs` is the one that covers the half a unit test cannot. It
forces the `web` presenter, which hands back a URL and opens no window, so the
screen claim, the detached viewer server and the scale probe are all exercised
without putting a browser on anyone's desktop:

    browserStatus -> {"daemon":"up","launch":"nested","presenter":"web",
                      "session":"live","vnc":"127.0.0.1:5900",
                      "tabs":"3 open, 1 orphan","wedged":"none","screenClaims":"0"}
    showBrowser -> open http://127.0.0.1:6096/?ws=127.0.0.1:5900 to take over
                   the browser, scale 1.601562
    browserStatus -> {... "screenClaims":"1"}
    hideBrowser -> dismissed
    viewer server: node src/Main.res.mjs --serve-viewer 6096

The scale is the fractional one `wlr-randr` reports rather than the integer
`wl_output` would round it to, which is `Geometry.host` preferring the first --
and the URL names the live session's real VNC port rather than the configured
one, which is what keeps a viewer off a dead session.

The emoji and the CJK are unescaped in both directions, which is
[056](../docs/wayfinder/tickets/056-utf8-escape-regression.md) and
[070](../docs/wayfinder/tickets/070-astral-still-escapes.md) not existing rather
than being fixed. The last two lines are ticket 057's finding held: the code and
the remedy reach the caller, because `Errors.rendered` puts both in the one
string the SDK reports.
