# What driving the page would cost, and what it would look like

Research for [Reaching content that sits behind an interaction](../tickets/004-driving-the-page.md).
Measured against the installed stack: patchright 1.62.1 attached over CDP to
Chrome 151.0.7922.137, on the daemon's own profile.

## How the peers address elements

Every browser MCP that drives a page has to answer "which element", and there
are only three answers in circulation:

- **Accessibility-tree refs.** Playwright MCP's default. Each interactive
  element in a snapshot carries a `ref` (`e5`), and `browser_click` takes the
  ref rather than a selector. The pitch is determinism -- no coordinates, no
  layout drift -- and cost: snapshots run 5-50KB of *text* against 100KB-5MB
  of screenshot needing a vision model.
- **Coordinates over a screenshot.** Playwright MCP keeps this as an opt-in
  `--caps=vision` mode, for canvases and pages with no useful semantics.
- **Nothing -- write the code.** `browser_evaluate` takes a function body and
  runs it. The generalisation of that is Anthropic's "code execution with MCP":
  the agent writes code against an API instead of calling one tool per step,
  which on their own measurements cut a task from ~150K context tokens to ~2K.

The first two both mean *rewrapping*: a tool per verb, each with its own
addressing scheme, and a snapshot in context per step. That is the machinery
the ticket was weighing, and it is a large amount of it.

## Where a passthrough lands instead

The steer for this effort is the third answer: expose the Playwright surface
directly rather than rewrapping any of it, and keep the project's scaffolding
-- session reuse, extraction, blocked-classification -- wrapped *around* the
call rather than around each verb. That inverts what has to be designed. There
are no per-verb tools to specify; what has to be specified is the envelope:

- **What the code is written against.** `page` is a patchright sync `Page`, so
  the whole API is reachable with no work. The agent already knows it.
- **What comes back.** A Playwright call returns handles, not values. Anything
  crossing the MCP boundary has to be JSON, so the envelope decides: the
  script's own return value, plus (optionally) an extraction of the page it
  left behind.
- **Where detection runs.** `classify` runs once per fetch today, after the
  single navigation. A script can navigate four times; a challenge can appear
  at step four. Running the existing probe/classify on the page the script
  ends on gives the same `blocked` outcome the agent already handles, for free.
- **Which page.** See the tab handle problem below.

Two properties of patchright shape the envelope and are easy to get wrong:

- **`evaluate` runs in an isolated world by default.** `isolated_context`
  defaults to `True` -- that is how patchright avoids `Runtime.enable`, whose
  side effects are what most CDP detection keys on. Measured: after a page
  script sets `window.log`, `page.evaluate("() => typeof window.log")` returns
  `undefined`, and only `isolated_context=False` sees it. A passthrough that
  hands `page` over inherits this. Scripts that read page globals must opt out
  explicitly, and opting out is the detectable path.
- **The console API is disabled.** `console.log` from injected script is not a
  debugging route here.

## What automated input actually looks like to a page

The ticket's fifth question -- whether driving the page costs the thing the
tool is for -- turns out to be answerable by measurement rather than by
argument. A page instrumented with capture-phase listeners on mouse and key
events, driven by `page.click`, `page.fill` and `page.keyboard.type`:

    click #b     mousemove(23,18) mousedown mouseup click     isTrusted: true
    fill  #i     input                                        isTrusted: true
    click #i     mousemove(130,18) mousedown mouseup click    isTrusted: true
    type  "xy"   keydown/input/keyup per character            isTrusted: true

Three things follow.

**`isTrusted` is not the tell.** Every event, including the ones from `fill`,
arrives trusted -- input dispatched over CDP is indistinguishable from real
input by that flag. Nothing here is fixable *or* detectable at that level.

**The cursor teleports.** Each click produced exactly one `mousemove`, at the
destination. Between the two clicks the pointer jumped 23,18 -> 130,18 with no
path in between. Published detection work keys on precisely this: straight
paths, absent jitter, and cursor traces whose frequency spectrum lacks the
8-12Hz peak human tremor produces.

**`fill` types nothing at all.** It produced a single `input` event: no
keydown, no keyup, no per-character timing. A site watching typing cadence sees
a field that filled itself. `keyboard.type(delay=...)` does emit real key
events, but at whatever uniform cadence the delay names.

This matters more in 2026 than it did when the ticket was written. Cloudflare's
Precursor moved detection from page-load fingerprinting to *continuous*
behavioural analysis over a session: mouse movement, typing rhythm, scrolling,
clipboard, page visibility. The profile this tool goes to such trouble to keep
warm is exactly what such a system scores over time, so a synthetic interaction
does not just risk the current page -- it risks the asset.

The honest reading is that the ticket's option (1) and option (2) differ in
kind, not degree. Reading the page a human navigated to costs nothing: no input
is dispatched, no behavioural signal is emitted, the session is not touched. A
script that clicks and fills spends session reputation every time it runs, on a
profile whose value is that it has never done anything unusual. A passthrough
that *can* do both leaves that spend to the caller, which is defensible only if
the difference is stated where the caller reads it.

## State across calls has a sharper edge than expected

The ticket asks what the tab handle is and what happens when it goes stale.
Probing for this turned up a defect that answers part of it, now filed as
[One wedged tab bricks every later call](../tickets/012-one-wedged-tab-bricks-every-call.md):
a single tab left mid-navigation makes `connect_over_cdp` hang forever, because
Playwright initialises every existing page target on attach and waits for all
of them. Measured 75s with no error; closing that one target took the attach to
0.28s.

A one-shot `fetch` mostly hides this by navigating its tab back to
`about:blank`. A driving sequence is the opposite: it keeps a tab alive across
calls *by design*, which is exactly the exposure. So whatever the handle turns
out to be, it needs a liveness story -- and the CDP HTTP endpoint
(`/json/list`, `/json/close/<id>`) keeps answering when the renderer does not,
which is what makes recovery possible at all.

## Sources

- [Snapshots | Playwright MCP](https://playwright.dev/mcp/snapshots)
- [Vision Mode | Playwright MCP](https://playwright.dev/mcp/vision-mode)
- [Code execution with MCP | Anthropic](https://www.anthropic.com/engineering/code-execution-with-mcp)
- [patchright-python](https://github.com/Kaliiiiiiiiii-Vinyzu/patchright-python)
- [Cloudflare Precursor: continuous behavioural bot detection | InfoQ](https://www.infoq.com/news/2026/08/cloudflare-precursor-detection/)
- [What Does It Take to Detect an AI Agent? (arXiv 2607.26935)](https://arxiv.org/html/2607.26935v1)
