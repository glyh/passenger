---
id: 078
title: Why the passenger Chrome drains the battery
labels: [wayfinder:research]
status: open
assignee:
blocked_by: []
---

## Question

The owner reports that running the passenger MCP drains the laptop battery
fast. Nobody has measured where the watts go, so every fix proposed so far is a
guess. This ticket measures first; a fix is a follow-up ticket.

076/077 answer one slice of it -- a browser nobody has used for hours is now
reaped. They do not answer the draw *while* it is alive, which is where the
report points: a session in use, or idle for less than the reap horizon.

## Suspects, none of them measured

1. **The three anti-throttling flags.** A hidden launch passes
   `--disable-background-timer-throttling`,
   `--disable-backgrounding-occluded-windows` and
   `--disable-renderer-backgrounding` (`Browser.res`, the `hidden` branch).
   They exist so challenge scripts are not stalled off-screen -- and their
   whole effect is that every background tab keeps running timers, animations
   and rendering at full rate. An ad-heavy tab left open by a lane burns CPU
   until its TTL collects it.
2. **The headless compositor.** sway + wayvnc rendering a Chrome window nobody
   is looking at. Does wayvnc encode frames with no client attached? Does sway
   run a frame clock for a headless output?
3. **Tabs outliving their use.** Lane TTL defaults to 1800s. Thirty minutes of
   an unthrottled video/ad page per forgotten lane.
4. **GPU / rasterisation path.** Whether Chrome under headless sway falls back
   to software rendering (SwiftShader), which is CPU-expensive for anything
   that animates.
5. **The watchdog and the serve processes** themselves -- polling loops,
   `Poll.until`, the reaper's clock. Expected negligible; confirm, do not assume.
6. **The profile.** The owner's real logged-in profile may carry extensions,
   sync, or service workers that a stock Chrome would not.

## To decide

1. **Which process tree draws the power**, apportioned: Chrome browser, each
   renderer, GPU process, sway, wayvnc, node. `powertop`, `top -b` over time,
   or per-process CPU time deltas from `/proc/<pid>/stat` -- whichever can be
   rerun by the next person.
2. **Idle vs. in use.** Measure three states: no Chrome (baseline), Chrome up
   with zero tabs, Chrome up with a typical lane's leftovers open.
3. **Whether suspect 1 is the answer.** Same states, flags removed. If it is,
   the question becomes whether throttling can be lifted only for the tab a
   `script` call is touching (e.g. CDP `Emulation.setFocusEmulationEnabled`, or
   `Page.setWebLifecycleState`) instead of for every tab, all the time.
4. **Whether a hidden window needs a compositor frame loop at all** between
   calls.

## Constraints

- **Stealth is the product.** Any flag change must not make the browser
  distinguishable from a human's daily driver. Record, per candidate fix,
  what page JS can observe.
- **The warm session is the product.** "Stop Chrome more often" is 076's
  question, already answered; do not reopen it here without new numbers.
