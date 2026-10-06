---
id: 088
title: Lift throttling for the tab a call drives, not for every tab
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

[Why the passenger Chrome drains the battery](078-chrome-power-usage.md) measured
the hidden launch's anti-throttling flags as the drain, and measured that
their whole cost is **background tabs**: with no flags at all, the active tab of
the window still ran at 20.02/s while the five behind it dropped to 0.57/s, and
of the three flags only `--disable-background-timer-throttling` did anything
(the two occlusion flags are inert under headless sway, where rAF runs at 60/s
either way). It also measured that **activating a tab moves that unthrottled
slot**: `Target.activateTarget` — the call Playwright's `page.bringToFront()`
makes — took page 3 from 0.57/s to 20.00/s and pushed page 1 down to 0.93/s, and
re-activating page 1 reversed it exactly.

So: drop the three flags, and make the tab a `script` call is driving the front
tab. What a caller leaves behind then gets throttled the way a human's browser
throttles it, instead of every tab running at full rate for as long as the TTL
lets it.

## Answer

Built, in two places:

- `Browser.res` — the hidden branch's three flags deleted, `--class` kept, and
the measurement that justifies the deletion written where the flags used to be,
so the next reader does not add them back.
- `Service.run` — `page->Pw.bringToFront` immediately after
  `Session.pageFor`, so it covers all three ways a tab is resolved (a reused
  blank, a new page, a named tab) and happens before the script body drives
  anything. `Pw.bringToFront` was already bound (`Pw.res:51`); nothing new was
  needed. A failure is swallowed on purpose: the page is still driveable, just
  slower if something else holds the front, and that is not worth ending a call
  over.

### Verified end-to-end, on the real path, not on the rig

`npm run compile` rebuilt `./passenger`; the MCP server this session talks to
was then spawned from that binary (pid 1755070, 13:44:57) and started a fresh
Chrome on demand — no rig, no hand-rendered session script.

| what | measured |
|---|---|
| the launch's own argv (generated `session.sh`) | `… '--no-default-browser-check' '--class=passenger' 'about:blank'` — no flags |
| Chrome processes carrying an anti-throttling flag | **0** |
| the tab a `script` call drove | **20.02 ticks/s** |
| a tab driven by an earlier call, left behind by the next one | **0.60 ticks/s** |

So the two halves are both real: the tab under a call runs at full rate with no
flags anywhere, and the tab nobody is driving gets Chrome's own throttling.
What the tool leaves is at most one unthrottled tab per browser — the front one,
which is what a human's daily driver looks like.

`npm test` is 154/154 and `npm run build` is rc=0 (one pre-existing warning 102
in `NestedSessions.res`, untouched by this).

### What this does not do, and what a reader should know

- **The flags were launch-time, so this takes effect at the next Chrome start.**
  `./passenger` is gitignored and built by `npm run compile`; three
  `passenger serve` processes belonging to other sessions on this machine keep
  running the old code until those sessions restart.
- **Every `script` call now foregrounds its tab**, including a call that only
  reads a background tab. That is the point — the tab under a call has to be the
  active one — but it is a visible change to which tab is in front.
- **The occlusion flags are dropped on the strength of headless sway never
  reporting the window as occluded** (078: rAF ran at 60.1/s either way). The
  front tab is the active tab of its window, so the argument holds for a backend
  that *does* report occlusion — but that is an argument, not a measurement.
- **079 and 080 still own the tab count.** This caps the multiplier at one tab;
  it does not stop tabs accumulating, and the active tab still runs unthrottled
  if a caller walks away from it.

