---
id: 079
title: A forgotten lane cannot be reclaimed by the caller that forgot it
labels: [wayfinder:grilling]
status: open
assignee:
blocked_by: []
---

## Question

A caller that stops holding a lane id has no way to close that lane's tabs, and
the only collection is wall-clock. The lane is alive, its tabs are open, calls
naming it have stopped — and nothing the caller can say will reach it.
`openLane` returns the id exactly once; no verb lists lanes (040 removed one on
purpose); `listTabs` needs an id it no longer has. So the remedy is to wait out
the TTL, with the tabs unthrottled for the whole of it — 078's suspect 1, since
the hidden launch passes `--disable-background-timer-throttling`,
`--disable-backgrounding-occluded-windows` and `--disable-renderer-backgrounding`,
which is precisely "every background tab keeps running timers, animations and
rendering at full rate".

**Should the lane id become recoverable by the caller that minted it, or should
the accumulation be removed at the source so there is nothing to reclaim?**

## What was measured, 2026-09-28

One agent session working a research task through this server, on the owner's
machine:

- **~12 lanes**, each opened for a single `script` call and never named again.
- Every one of those calls passed no `tab`, so each minted a fresh tab. The
  skill says this in as many words — *"a `script` with no `tab` opens a fresh
  one every call"* — and it still happened, because the id it would have passed
  back is not the thing the caller is looking at.
- `browserStatus` mid-session: **`40 open, 1 orphan`**, shared by three callers
  (the session plus two subagents), all of them through lanes.
- Of that pile, the session could close exactly **one** tab: the `orphan` —
  readable and closable by any caller, and the one class with no TTL.
- Two of the twelve lanes were still nameable, because their ids happened to
  reach the conversation. Both were gone by the time anything asked:
  `LANE_NOT_FOUND ... it expired, or never existed`.

The count fell only by waiting. Nothing in the session could accelerate it.

## What this is not

- **Not a request to list lanes.** [A lane owns its
  tabs](040-a-lane-owns-its-tabs.md) wrote a `passenger lanes` command, deleted
  it, and said why: *"a view that exists gets used, and then isolation is a
  convention rather than a property."* Reopening that needs an argument, not a
  restatement — and it has to survive the fact that 040's own closing note
  already names this hole: *"nothing enforces that a caller ever calls
  `destroy_lane`: the TTL is the only collection, which is why it is the one
  number an agent can change."* The hole was left standing knowingly; what
  changed is that it has now been walked into.
- **Not 078.** [Why the passenger Chrome drains the
  battery](078-chrome-power-usage.md) measures where the watts go and lists
  this accumulation as suspect 3. That is a power question; this is not. The
  leak is present whether or not the anti-throttling flags stay, and would
  still be wrong at zero watts.
- **Not the TTL.** Thirty minutes is 040's number and 078's horizon. This is
  about the caller having no handle on a live lane, not about how long it
  waits.

## Directions, none of them costed

1. **Nothing.** The skill's sentence is the remedy and the TTL is the backstop —
   040's position, and the one to beat rather than restate. If it holds, the
   answer is to say where the caller is *supposed* to have written the id down,
   which is nowhere.
2. **An idempotent handle.** The caller passes a name it chose; the daemon keys
   the lane by it, so re-opening is re-attaching. 040 refused caller-chosen
   names for the collision reason — two subagents both pick `"scratch"` — but a
   collision only exists once something keys on it, and 040 records that stdio
   supplies no identity (`Context.session_id` is `None`). Whether one can be had
   cheaply is unexamined.
3. **Do not mint a tab.** A `script` with no `tab` reuses the lane's last tab,
   and opening a new one becomes the explicit act. This removes the accumulation
   at the source and adds no view, so it never touches 040's visibility rule —
   but it changes what `script` means, and `Page.goto` into a reused tab is not
   the same thing as a clean one.
4. **Make the leak visible only to the leaker.** `browser_status` is a count and
   not a listing on purpose, so it cannot say whose. Telling a caller *its own*
   number names no other lane, and is the version of 040's rule that has not
   been tried.

## Constraints

- **Stealth and the warm session are the product.** Whatever lands must not make
  the browser distinguishable from a human's daily driver, and must not throw
  away the logged-in profile to get isolation.
- **The caller is an agent reading a schema, not a human reading a skill.** The
  measurement above is a case of the right rule being in the wrong place: it is
  written down, it was read, and it did not bind. Any answer resting only on
  prose has already failed once here.
