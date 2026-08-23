---
id: 041
title: One screen for everyone, or one window each
labels: [wayfinder:task]
status: open
assignee:
blocked_by: []
---

## Question

There is exactly one screen, and everything above it is singular. One cage
compositor holds one Chrome; one wayvnc serves that compositor; `session.env`
records *the* session and `session.live()` returns it or nothing;
`WindowPresenter.presented()` asks whether *our* one viewer pid is alive, and
`present()` short-circuits with "viewer already open" if it is
(`present.py:127`). `show_browser(tab=...)` does not open anything -- it brings
a tab to the front of the single Chrome window
(`handoff.bring_to_front`, `mcp_server.py:158`).

[040](040-a-lane-owns-its-tabs.md) had to design around this. Lanes partition
tabs, and the screen was the one thing they could not partition, so it is
refcounted instead: `show_browser(lane)` claims it, `hide_browser(lane)`
releases, and the viewer comes down when the last claim goes. That is the
cheapest thing that stops one lane yanking the window away from another lane's
human. It is not the same as two humans looking at two pages at once, and it is
not the same as one human with two windows.

So: what would it take for the MCP surface to hand out **more than one display
window**, and which of the several things that phrase could mean is worth
building?

**What it might mean.** These have almost nothing in common technically, and
the ticket should not proceed until one is chosen:

1. *Several viewers onto the same screen.* Two browser windows, or one on a
   phone and one on the desktop, both attached to the same wayvnc, showing the
   same framebuffer. Cheap -- the viewer is a noVNC page and RFB is happy with
   multiple clients. Blocked today only by bookkeeping: one `viewer.pid`, and
   `present()` returning early when it is set. This is "let me watch from the
   couch", not isolation.
2. *One window per lane.* Lane A's human solves a captcha while lane B's human
   logs in, on two independent screens, neither seeing the other. This is what
   would make 040's refcount unnecessary, and it is the expensive one.
3. *Several Chrome windows on one screen.* One compositor, one framebuffer,
   several toplevels -- so a human sees several pages side by side but a viewer
   still shows all of them. Changes nothing about isolation; may still be worth
   it for a human comparing two pages.

**Why 2 is hard, concretely.** Chrome will not run two processes on one
`--user-data-dir`; the second forwards to the first and exits. So one profile
is one Chrome, and the warm logged-in profile is the entire point of this tool
-- a second profile would be a second, cold browser, which is the same trade
that disqualified per-lane `BrowserContext`s in 040. That leaves one Chrome
whose windows must land on separate *outputs*, and wayvnc serves an output
(`-o`), not a window. cage is a single-output kiosk compositor, so this would
mean replacing it with a wlroots compositor that can create several headless
outputs, one wayvnc per output, one port per output, and a way to pin a Chrome
window to an output. Every one of those is plausible; none of them is small,
and cage was chosen for good reasons.

**What the code already half-anticipates.** `session.py` scans 64 ports for a
free one and the record carries the port it actually got, precisely so a second
session does not inherit the first's hardcoded port -- that was the black-screen
bug this whole map started from. So the *port* story is already plural. The
*record* is not: one `session.env`, one `viewer.pid`, and `live()` singular.
Whatever this becomes, that record is the thing that changes shape.

To decide:

1. **Which of the three.** 1 is a day's bookkeeping and a real quality-of-life
   win. 3 is modest. 2 is a rewrite of the launch layer. They are not stages of
   one another -- 1 does not lead to 2.
2. **Whether 2 has a caller.** 040's refcount already prevents the interference
   that matters. The remaining case is two humans, or one human genuinely
   working two handoffs at once. If that case is hypothetical, 2 is machinery
   for nobody, and [the layer stays
   thin](020-how-thin-can-this-layer-get.md) says so.
3. **What the MCP surface would even say.** `show_browser` returns a string
   today. Plural windows means it returns *which* window, and `hide_browser`
   takes one -- another handle for the caller to hold, on top of `lane` and
   `tab`. Under 1, the answer might be that nothing changes in the tool at all:
   the URL is already handed back by `LinkPresenter`, and a human who wants a
   second view opens it themselves.
4. **Who observes presence.** `observes_presence` exists because the human
   closing the viewer is the one completion signal this tool does not have to
   infer (018). With several viewers, "the human closed it" becomes "which one,
   and does the wait end when the first closes or the last?"
5. **Whether this replaces 040's refcount or sits beside it.** If 2 is built,
   per-lane screens make the claim table redundant. If 1 or 3 is built, the
   refcount stays and this ticket is orthogonal to it.
