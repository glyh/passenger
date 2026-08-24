---
id: 042
title: A tab waiting on a server that never answers hangs every attach
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question


[One wedged tab bricks every later call](012-one-wedged-tab-bricks-every-call.md)
closed on a tab whose *renderer* has stopped answering: `Page.getFrameTree` gets
no reply, `Page.stopLoading` frees it, and `targets.unstick` is built on exactly
that difference. There is a second wedge it does not catch, and it hangs the
attach just as hard.

**Measured** on a throwaway Chrome, against a socket that accepts and then
answers nothing (`accept()`, never write). One tab navigated to it:

    attach with the tab open      ATTACH-FAILED after 30.8s (15s, twice)
                                  "no tab was stuck mid-navigation,
                                   so this is something else"
    targets.unstick()             0.0s, stuck=0
    attach with the tab closed    attached in 0.4s

So the tab is unmistakably the cause, and `unstick` reports the browser as
healthy while it is the thing making every call fail. The reason is that the
renderer *is* healthy: it is parked waiting for response headers, and it answers
`Page.getFrameTree` instantly. 012's probe is a renderer-liveness probe, and
this tab is alive. What is pending is the navigation, not the renderer.

The failure is silent in the worst way, because the detail line is *honest and
wrong-footed*: "no tab was stuck mid-navigation, so this is something else; try:
`passenger stop`" sends a caller to restart a browser whose only problem is one
tab on a slow host -- and a restart throws away the warm logged-in session that
is the entire point of this tool.

Found while porting `Session._attach` to C# for [Whether this moves to
C#](023-rewriting-into-csharp.md); the port reproduced the behaviour exactly,
which is what showed it was the design and not the code.

To decide:

1. **Whether the probe can tell this apart from a slow page at all.** A tab
   waiting on headers and a tab loading a genuinely slow site look identical
   from outside -- both answer `Page.getFrameTree`, both have a pending
   navigation. `Page.stopLoading` on the wrong one stops a fetch someone wanted,
   which is the cost 012 was careful about. Whether there is a signal that
   separates them (time since navigation started, `Network` events having gone
   quiet, `Page.getNavigationHistory`) is unknown and is the first thing to
   measure.
2. **Whether the attach should care.** The alternative to detecting it is not
   attaching to it: `connect_over_cdp` initialises every open tab because that
   is what Playwright does, and this whole class of bug comes from that one
   fact. Ticket 012 already recorded that it cannot be fixed while one profile
   means one Chrome. Worth re-asking whether a CDP-level attach that does not
   initialise every page is reachable, since `targets.py` already talks to
   Chrome without patchright for exactly this reason.
3. **What the message should say when the probe finds nothing.** Today it
   asserts the negative -- "so this is something else" -- on the strength of a
   probe that only looks for one of at least two wedges. Even with nothing else
   fixed, saying what was *checked* rather than what is *therefore true* would
   have saved the trip to `passenger stop`. This is the cheap half and it is
   worth doing regardless of 1 and 2.
4. **Whether a pending navigation should be visible in `status`.** `status`
   reports a tab count (040). A tab that has been navigating for four minutes is
   the thing a human would want named, and it is already in `/json/list` reach.

## Answer

There are two wedges, not one, and they wear opposite symptoms. 012's tab is
*silent*: it holds a document and its renderer answers nothing. 042's is
*uncommitted*: it answers everything in under 10ms and holds no document at
all, because the navigation that created it is still waiting on headers. Both
hang `connect_over_cdp` equally hard. `targets.unstick` now knows both, and
frees each with its own remedy.

Measurements: [Two ways a tab holds the attach open](../assets/042-two-wedges-findings.md).

**1. Whether the probe can tell this apart from a slow page at all.** Yes, and
the question turned out to be smaller than it looked. A tab that has *committed*
never hangs the attach, however slowly the rest of it arrives -- a page dribbling
its body forever attaches in 0.2s. Only the window between "navigation started"
and "first response byte" hangs it, and inside that window a dead server and a
slow one are the same state, so nothing tries to separate them. The signal that
does separate a pre-commit tab from every healthy one is the frame's URL: the
empty string, which is Chrome for "no document here", and which `about:blank`
is not. `targets.verdict` reads exactly that, and it is pure and tested.

This does mean a tab on a merely slow host can be stopped. It is affordable
because `unstick` runs only after an attach has already timed out: the same
navigation has been failing every call in every lane for the whole timeout, and
re-navigating is cheap where a bricked tool is not. It is the same trade 012
made, on a tab with strictly less to lose.

**2. Whether the attach should care.** Left where 012 left it. Nothing here
needs it any more: both wedges are now detected and freed through the browser
endpoint, which is what `targets.py` exists for. An attach that does not
initialise every open page is still the structural fix, still unreachable
without patching patchright's `connect_over_cdp`, and still gated on one
profile meaning one Chrome.

**3. What the message should say when the probe finds nothing.** Done, and it
was the cheap half as predicted. It now says what was *checked* -- "every tab
answered its renderer probe and every one of them holds a document, so neither
wedge this knows how to free is present" -- and names `passenger status` before
`passenger stop`, with the cost of `stop` said out loud: it restarts Chrome and
the warm logged-in session goes with it.

**4. Whether a pending navigation should be visible in `status`.** Yes, on both
doors: `wedged: none`, or `1 uncommitted`, or `1 silent`. A count per wedge and
no more, following 040 -- which tab, in whose lane, would be a listing, and a
lane's tabs are nobody else's business. It costs one websocket round trip per
tab on a call that is already a diagnostic, and a healthy tab answers in under
10ms; the deadline there is 1.0s rather than the rescue path's 3.0s, because
nothing is freed on the strength of the answer. A tab merely mid-navigation is
counted as `uncommitted`, which is honest: it *is* navigating, and this reports
that rather than ruling on whether it is stuck.

78 → 83 tests, mypy strict clean. The five new ones are pure: `verdict()` reads
one recorded `Page.getFrameTree` answer and names the wedge, so the distinction
this ticket turns on is asserted without a browser.
