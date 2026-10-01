# Tabs, lanes, and the shared browser

`SKILL.md` has the part you cannot work without: open a lane, and it collects
itself after 30 minutes of quiet. This is everything else about the machinery
you are sharing.

## Closing things

```
closeTabs(lane, [tab, ...])    the ones you name
closeAllTabs(lane)             every tab in your lane; the lane survives
destroyLane(lane)              the tabs, then the lane itself
```

**There is no "close everything" reachable by omitting an argument.** That was
the old shape, and it is what closed other callers' tabs.

**Tabs accumulate faster than they used to.** A `script` with no `tab` opens a
fresh one *every call*, so twenty pages driven one call each leave twenty tabs.
Pass the `tab` back from the previous reply when working through a list, and
close what you are done with.

Popups a page opens for itself accumulate too, and so does every tab that came
back `blocked` — that one keeps its wall on purpose, because it is the tab the
human needs.

Tabs left open cost memory in a browser meant to stay warm for weeks. The TTL is
a backstop for calls you never got to make, not the plan.

## The screen is shared and refcounted

`showBrowser` claims it. The viewer stays up until every lane that claimed it
has called `hideBrowser`. **Your `hideBrowser` cannot take the window away from
someone else's human, and theirs cannot take it from yours.**

It is a claim on the screen and nothing else. It closes no tab and ends no lane,
whatever the name suggests: after `hideBrowser` your pages are still loaded and
still yours. `closeTabs` closes pages; `destroyLane` ends the lane.

## What crosses the glass

The human is looking at a VNC screen in a browser window, so what reaches the
session is what RFB carries: keystrokes, pointer movement, and clipboard text.

**The clipboard works both ways, but only after a focus change.** The viewer
reads the host clipboard when its window *gains* focus, so the sequence is: copy
on the host, click into the viewer, paste. Text copied while already inside the
viewer does not cross until the window has been left and returned to. Say "copy
it, then click the browser window" rather than just "paste it".

**CJK cannot be typed; it must be pasted.** Nothing in the session composes, so
no IME is available — a human cannot type Chinese into the browser they were
just handed. The machinery to lend them the host's fcitx5 exists and is turned
off, because attaching it segfaults the nested Chrome (ticket 067). When someone
says they cannot type, the answer is: copy it on your own machine, click the
browser window, paste.

**Files do not cross by dragging, and never will.** RFB has no file transfer, so
dropping a file on the viewer does nothing — deliberately, since the alternative
was the *host* browser opening it in a window of its own. The way in is the
page's own file input: clicking it opens a file chooser on the human's desktop,
from which any path on the machine can be picked, and the file arrives in the
nested page. **When a site wants an upload, say "click the upload button and
choose the file", never "drag it in".**

Dragging *within* the page — a slider, a reorder, an HTML5 drop target — works
normally, because that is only pointer movement.

## `orphan` is a junk drawer anyone may open

Tabs a page opened by itself join the lane that caused them. But a tab a *human*
opened during a handoff has no opener for Chrome to trace, so it lands in
`orphan`: readable and closable by any caller, and never collected on a timer.

`listTabs("orphan")` is how you look, and **looking first is the whole
etiquette** — somebody may be halfway through a login in there.

## What lanes do not isolate

**Availability.** One profile means one Chrome and one attach, and attaching
initialises every open tab. So a tab wedged mid-navigation in *any* lane slows
or fails calls in every lane, and freeing it can stop a navigation another lane
was making. **Lanes partition ownership, not availability.** When it happens the
tool says which lanes it touched; it cannot prevent it.

`browserStatus` reports `wedged:` for exactly this — `none`, or a count per
kind. Read it when calls have gone slow for no visible reason: the tab causing
it is usually not yours, and the count is the only thing that says so.

**A site.** Agents working the same domain at once share everything that domain
counts — the account, the profile, the address — so they throttle each other,
and a throttled reply is an ordinary-looking page. Running two variants of the
same scrape side by side is the worst case: neither run can distinguish the
site's behaviour from its own interference. **Keep concurrent work on one domain
low, and prefer one agent per site.**

## When a lane is gone

A lane that expired returns `LANE_NOT_FOUND` on the next call, with its tabs
already closed. **Nothing is recoverable and retrying will not help** — open a
new lane and start again.

The usual way to get there is a handoff the human took longer over than you
allowed for, which is what `ttlMinutes` and `setTtl` are for.

The other way is the browser itself stopping. It stops after
`PASSENGER_IDLE_STOP` — 45 minutes by default — in which nobody, in any lane,
called anything, and every lane goes with it. When that is what happened, the
`LANE_NOT_FOUND` says so in its detail, and `browserStatus` reports the same
line under `lastIdleStop` for as long as it stands. **The remedy is the same:
open a new lane.** The next call starts a fresh browser on its own, so nothing
has to be restarted by hand — but the logins are still there, since the profile
outlives the process, and only the tabs are gone.

A lane you set a long `setTtl` on is not exempt: that clock is the lane's, and
this one is the browser's. A wait longer than 45 minutes needs the setting
raised, not the lane's TTL.
