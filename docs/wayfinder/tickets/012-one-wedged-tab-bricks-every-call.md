---
id: 012
title: One wedged tab bricks every later call
labels: [wayfinder:task]
status: closed
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

## Answer

Bounded the attach, and made a failed one recover itself. Nothing is closed:
the pending navigation is stopped instead, so the tab keeps the document it
already had.

**There turned out to be two holders, not one, and the second was ours.**

1. *A navigation that never lands.* The renderer stops answering: measured,
   `Page.getFrameTree` gets no reply at all where a healthy tab answers in
   under 10ms, and `Page.stopLoading` on that same tab is answered instantly
   and makes it answer everything again.
2. *The abandoned attach itself.* A `connect_over_cdp` timeout only gives up
   on the Python side -- the driver carries on attaching, and its half-done
   attach has `Fetch.enable` interception on every request with nobody left to
   continue them. Freeing a tab underneath it also kills it: it dies on an
   uncaught `Network.setCacheDisabled` protocol error and takes the retry with
   it. So the driver is torn down *first*, and the retry runs on a fresh one.

Recovery cannot go through patchright, since patchright is what is stuck. It
speaks to the browser process directly instead -- `/json/list` for the targets
and each page's own websocket for the two commands -- which is exactly the part
that keeps answering when a renderer does not. That is `ab/targets.py`, and it
is why `websockets` is now a dependency: the CDP HTTP endpoint can enumerate
and close targets, but it cannot ask one a question.

On the four things the ticket listed:

1. **Bounded.** `AGENT_BROWSER_ATTACH_TIMEOUT`, 15s by default -- really a
   budget for the slowest open tab, since attaching initialises all of them.
2. **Freed, not reaped.** Every page is asked one question; the silent ones
   are told to stop loading. Then one retry.
3. **Nothing new about leaving tabs.** A tab that hangs mid-navigation never
   reaches the line that would have cleaned it up, so prevention was never
   going to be the fix. `close_tabs` keeps its current default.
4. **Scope kept.** Only this profile's Chrome is ever contacted, and the worst
   that happens to a tab is that a navigation stops.

**What this costs.** A page still legitimately loading after the whole budget
is indistinguishable from a stuck one -- measured: a page that takes 15s to
send its first byte looks exactly like a blackhole from the outside, and the
target list cannot tell them apart either (a stuck tab keeps the *previous*
document's title, which is why the probe asks the renderer rather than reading
fields). So a concurrent fetch of a very slow site, in another process, can
have its navigation stopped by this. That is the trade this makes: a stopped
navigation can be retried, where the hang it replaces could not.

Measured after the change: a tab wedged mid-navigation is freed, the attach
completes, every tab stays open on its own document, and an ordinary fetch is
unaffected (3.2s, 4,441 words).

Left standing: `browser_status` reports nothing about tabs, so the state this
ticket is about is still invisible until something goes wrong.
