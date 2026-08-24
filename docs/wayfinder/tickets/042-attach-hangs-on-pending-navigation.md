---
id: 042
title: A tab waiting on a server that never answers hangs every attach
labels: [wayfinder:task]
status: open
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
