---
id: 040
title: A lane owns its tabs, and no caller closes another caller's
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

Tabs are a single global pile with no owner, and two collisions follow with no
exotic setup:

    close_tabs()      ->  closes every tab but one blank keeper
    page(reuse=True)  ->  hands back *any* about:blank tab it finds

So one caller's `close_tabs` closes the tab another is halfway through driving,
and one caller's `fetch` is handed the blank tab another opened a moment ago
and has not navigated yet. `close_tabs` takes no argument at all
(`mcp_server.py:194`); its whole vocabulary is "everything except a keeper"
(`browser.Session.close_other_tabs`, `browser.py:257`), and the keeper exists
only because Chrome exits when its last tab closes -- a browser-lifetime
device, not an ownership one.

**Who can collide.** `server.run()` is stdio (`mcp/server/mcpserver/server.py:357`),
so one MCP client is one `passenger-mcp` process, and two Claude Code sessions
are two processes sharing one Chrome. But subagents inside one session share a
single process *and* a single connection -- so connection identity cannot
separate them, and `Context.session_id` is `None` on stdio anyway
(`mcp/server/context.py:92`). The parties most likely to hammer one browser in
parallel are exactly the ones the transport cannot tell apart.

## The shape

A caller asks for a **lane**. Every tab it opens is opened in that lane;
`list_tabs` shows only that lane; `close_tabs` closes tabs it names; nothing
outside the lane can see or touch them. The daemon, the profile and the warm
login stay shared -- a lane partitions *tabs*, not the session.

The word is not `sink`. A sink is where a stream goes to die; this is a scope
of ownership with a lifetime, and "no lane can interfere with another lane"
reads as literally true in a tool that is already [a seat in a car someone else
is driving](033-rename-to-passenger.md).

**Lane ids are minted server-side.** `open_lane()` returns an opaque id.
Caller-chosen names save a round trip and collide the moment two subagents both
pick `"scratch"`, which is the failure this ticket exists to remove.

**`lane` is required, not defaulted.** Every tab-touching tool takes it:
`fetch`, `script`, `list_tabs`, `close_tabs`, `close_all_tabs`, `show_browser`,
`hide_browser`. Only `browser_status` is lane-free. An implicit lane keyed by
pid was considered and rejected: it isolates by accident rather than on
purpose, and the caller cannot tell which lane it is in.

**A destructive call never expresses "everything" as an omitted parameter.**
That is today's bug in miniature, so the three verbs are separate rather than
one with an optional selection:

    open_lane()                     -> lane id, TTL 30 min
    set_ttl(lane, minutes)
    close_tabs(lane, [tab, ...])    -> the named tabs, required
    close_all_tabs(lane)
    destroy_lane(lane)              -> closes its tabs first, then the lane
    show_browser(..., lane, ttl=None)

`destroy_lane` must close the tabs, not merely drop the row: tabs with no lane
would have no owner, no clock and no caller who can see them.

Eleven tools where there were seven. That is real pressure against [how thin
can this layer get](020-how-thin-can-this-layer-get.md), and the trade is
deliberate: the alternative is an omitted argument that means "close
everything."

## The registry

**SQLite under `state_dir`.** Stdlib, no new dependency, real transactions
instead of a hand-rolled lock -- and a lock is needed, because two
`passenger-mcp` processes write it concurrently. It follows the idiom
`session.py` already set: the imperative shell keeps the one record that knows
a correlation nothing else in the system does.

Chrome stays the source of truth for *existence*; the table only adds
*ownership*, keyed by CDP target id (`Session.target_id`, stable across calls
and attaches). `/json/list` -- what `targets.listing()` reads -- does not
report `browserContextId`, so there is no cheaper place for this to live.

**A real `BrowserContext` per lane is the elegant answer and it is
disqualified.** Membership would live inside Chrome and be readable by any
process for free. But CDP browser contexts are incognito-like: separate cookie
jar, separate storage. That destroys the one warm logged-in profile this tool
exists to be. Written down here so nobody reopens it in three months.

**The table dies with the browser.** Target ids are not reused across a Chrome
restart, so stale rows are worse than no rows. `browser.start()` already calls
`session.reap_stale()` before launching; the table is dropped there. No epoch
column -- there is no reading of an old epoch that is ever useful.

## Lifetime

**TTL, default 30 minutes, and expiry closes the lane's tabs.** Not pid
liveness, which would need `/proc` and would keep a subagent's lane alive for
the whole session; not release-of-ownership, which leaves today's unbounded
pile with a registry bolted on. Columns: `ttl_seconds`, `touched_at` (unix
epoch, wall clock -- monotonic does not cross processes).

Every call naming a lane refreshes `touched_at`, on entry *and* on return: a
`script` with `timeout_seconds=600` or a `show_browser` with `wait_seconds=900`
must not expire underneath itself. Sweeping is opportunistic at the top of any
call that touches the registry -- no background thread, same shape as
`reap_stale`.

**The handoff case is the agent's to manage.** `fetch` returns `blocked`, the
agent asks the user, the user wanders off for forty minutes: under expiry the
tab with the wall on it is gone, against [018](018-asking-for-a-human.md)'s
rule that a blocked tab is the one tab the caller still needs. The answer is
`show_browser(..., ttl=)` and `set_ttl` -- knobs the agent turns when it knows
it is about to wait -- not a rule that pins tabs the tool has decided are
precious. That judgment is what [038](038-a-fetched-that-says-this-reads-like-a-wall.md)
keeps out of the tool.

## Two reserved lanes

**`cli`.** The CLI is a human at a terminal, and `passenger fetch <url>` then
`passenger script --tab <id>` is two processes thirty seconds apart. A minted
id would have to be copied by hand; an ephemeral per-invocation lane would
break the second command outright. So the CLI uses lane `cli` when `--lane` is
absent -- a row like any other, same TTL, same sweep, just a fixed and
guessable id. No longer default TTL for it: a special-cased number is a thing
nobody remembers is there, and `passenger set-ttl cli 240` exists.

**`orphan`.** A page that calls `window.open`, or a link with
`target="_blank"`, creates a target with no row: invisible to everyone,
closable by nobody, and never collected, because the sweep collects *lanes*.
Chrome reports `openerId` from `Target.getTargets`, and `targets.py` already
speaks that websocket -- so a target whose opener is a tab in lane A joins lane
A. That leaves the openerless ones, which are overwhelmingly tabs a **human**
opened during a handoff. They land in `orphan`, which any caller may read and
close, and which has no TTL.

`orphan` is a junk drawer and is documented as one. An agent can empty it while
a human is mid-login. A freeze-while-the-screen-is-claimed rule was considered
and rejected as machinery for a rare case.

## The screen is refcounted

Lanes divide tabs. They do not divide the compositor, the VNC server, or the
viewer window. Today `hide_browser()` takes no arguments and dismisses the
presenter globally (`mcp_server.py:167`) -- so lane A summons a human for a
captcha and lane B's unrelated `hide_browser` thirty seconds later takes the
window away mid-solve. That is one lane interrupting another.

`show_browser(lane)` adds a claim, `hide_browser(lane)` drops that lane's
claim, and the viewer comes down when the last claim goes. Lane expiry drops
its claims. One more table in a database that is already there, and it turns
`hide_browser` from a global verb into "I am done with it", which is what the
caller means.

## What lanes do not isolate

**The attach.** `connect_over_cdp` initialises every open tab and waits for all
of them, so a tab wedged in *any* lane hangs the attach for *every* lane -- and
lanes, by design, grow the tab count, which tightens the 15s budget for
everyone. Worse, [012](012-one-wedged-tab-bricks-every-call.md) closed with
this sentence: *"a concurrent fetch of a very slow site, in another process,
can have its navigation stopped by this."* That is lane B's recovery stopping
lane A's navigation, written a year before lanes existed, and `targets.unstick`
sweeps every page rather than the caller's.

Lanes partition **ownership, not availability**. One Chrome, one profile, one
attach, all tabs. This is not fixable short of separate profiles, which throws
away the warm session, so it is stated rather than solved -- in the ticket, the
docstrings and the skill.

What it does get is legibility: `unstick` reports which lanes it touched, and
the attach error names them, so a lane whose fetch died learns why instead of
seeing an inexplicable failure. That is this map's standing move -- the
founding incident was a stack silently broken while every status read healthy,
and the fix there was never prevention, it was making the failure nameable.

**`browser_status` grows a count.** `"tabs": "12 open, 3 orphan"` -- no ids, no
lanes, just numbers. Under the visibility rule there is otherwise no view
anywhere in this tool that reveals a lane you do not own, and 012 closed with
"Left standing: `browser_status` reports nothing about tabs." A count is a
measurement, which is the side of the line this tool is allowed on.

## Answer

Built as designed. `passenger/lanes.py` is the whole registry -- sqlite under
`state_dir`, dropped by `browser.start()` alongside `session.reap_stale()`.

**Closing left patchright entirely.** The design said a lane's tabs would be
closed through a `Session`, and that turned out to be both slower and wrong:
an attach initialises every open tab, which is a strange price for closing one,
and it is the thing that hangs when a renderer is wedged. `targets.py` already
existed for exactly that reason, so `targets.close` (`/json/close/<id>`) and
`targets.openers` (`Target.getTargets` over the browser socket, for `openerId`)
were added there, and no tab bookkeeping needs an attach any more. That also
made the sweep cheap enough to run at the top of every call.

**The keeper became an invariant rather than a tab.** The plan was a permanent
unowned `about:blank` that no sweep touches. Naming a particular tab as sacred
turned out to need protecting on every closing path, so the rule lives in
`lanes.close_tabs` instead: whatever is asked for, one page stays. It lands in
`orphan` on the next reconcile, which is the right home for a tab that exists
only so Chrome keeps running.

**`FetchRequest.close_tabs` stayed and became lane-scoped.** `close_other_tabs`
is now `Session.close_others(lane, keep)`, which can only reach the caller's
own tabs.

**Two exemptions from the visibility rule were considered and refused.** A
`passenger lanes` command listing every lane was written and then deleted: a
view that exists gets used, and then isolation is a convention rather than a
property. `passenger status` reports the count and nothing else. The other was
`passenger hide --force`, which *stayed* -- a human overriding another lane's
screen claim is exactly the escape hatch an agent must not have.

**Measured against the live daemon**, with twelve of the owner's real tabs
open: those twelve were adopted into `orphan` and never touched; a fetch into
lane A left its tab invisible to lane B; lane B naming A's tab got
`TAB_NOT_FOUND`; lane B's `close_all_tabs` closed nothing of A's; and a
`window.open` from A's tab joined lane A rather than leaking.

75 tests pass, 21 of them new, and `mypy --strict` is clean on `passenger`.

**What this costs.** Eleven MCP tools where there were seven, against
[020](020-how-thin-can-this-layer-get.md), and a required parameter on the
90% call. And lanes still do not partition the attach: one profile is one
Chrome, so a tab wedged in any lane hangs every lane, and freeing it can stop
another lane's navigation. That is said out loud now -- `unstick` names the
lanes it touched, in the attach error and on stderr -- and it is not fixed.

**Left standing.** The registry is unit-tested; opener adoption against a real
popup and the refcount across two live processes are covered only by the smoke
run above, not by the suite ([001](001-testing-the-shells.md)). And nothing
enforces that a caller ever calls `destroy_lane`: the TTL is the only
collection, which is why it is the one number an agent can change.
