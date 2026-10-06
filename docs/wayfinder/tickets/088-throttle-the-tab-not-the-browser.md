---
id: 088
title: Lift throttling for the tab a call drives, not for every tab
labels: [wayfinder:task]
status: open
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

