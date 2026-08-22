---
id: 012
title: One wedged tab bricks every later call
labels: [wayfinder:task]
status: open
assignee: lyh (via Claude)
blocked_by: []
---

## Question

A tab left mid-navigation makes `browser.Session()` hang **forever**, and
every entry point builds a Session first -- so the CLI, the MCP server and
anything else attaching to that Chrome all stop working until a human finds
the tab and closes it.

Measured on the live daemon. Two tabs were open: `about:blank`, and a
`xiaohongshu.com/search_result?...` left behind by an earlier run. With
`DEBUG=pw:protocol`, `connect_over_cdp` initialises **every** existing page
target -- `Page.enable`, `Page.getFrameTree`, `Network.enable`, ... -- and
waits for all of them. The stale tab answered only the browser-process
commands (`Fetch.enable`, `Target.setAutoAttach`) and never answered a single
renderer one; its last event was `Page.frameStartedNavigating`, a navigation
that started and never committed. No CDP command went unanswered by the
*browser*; the connect simply never returned. 75s with no error, no timeout,
no way to tell what was wrong from the outside.

Closing that one target over the HTTP endpoint took the connect from
unbounded to **0.28s**.

Reproduced deliberately, so the mechanism is not in doubt: open a tab on a
blackholed address (`http://10.255.255.1:81/hang`) and connect hangs again.
Passing `connect_over_cdp(..., timeout=8000)` turns it into a clean
`TimeoutError` at 8.2s. We pass no `timeout` today, so the default is
unbounded.

The renderer was idle at 0% CPU and nothing was attached to port 9222 at the
time, so this is neither a busy loop nor a leaked connection: a tab can enter
this state on its own and stay there indefinitely.

What to decide:

1. **Bound the attach.** A `timeout` on `connect_over_cdp` turns a hang into
   an error. Necessary, not sufficient -- an error every time is still a
   dead tool.
2. **Reap what wedged.** The CDP *HTTP* endpoint stays healthy when a
   renderer does not: `/json/list` enumerates targets and `/json/close/<id>`
   closes them without needing the renderer to answer. So the recovery path
   is: attach with a timeout, and on timeout find the unresponsive page
   targets, close them, retry. How is "unresponsive" told apart from
   "legitimately slow" -- and is one retry enough?
3. **Stop leaving tabs.** `keep_tab` defaults to False and `fetch` navigates
   the tab back to `about:blank`, but a tab that hangs mid-navigation never
   reaches that line. Whether `close_tabs` should default on, or a reap
   should run at Session enter the way `reap_stale` runs at start.
4. **Scope.** Only tabs in our own profile are ours to close. The current
   `close_other_tabs` already works that way; a reaper driven off the HTTP
   endpoint should keep that property.

This is the concrete form of the fog note "Nothing notices a session dying
mid-fetch", and it bears directly on
[Reaching content that sits behind an interaction](004-driving-the-page.md):
driving a page keeps tabs alive across calls by design, which is exactly the
exposure this defect punishes.
