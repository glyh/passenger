---
id: 080
title: A fleet of callers exhausts the machine, and the caller that leaks is not the one that read the schema
labels: [wayfinder:grilling]
status: open
assignee:
blocked_by: []
---

## Question

[A forgotten lane cannot be reclaimed by the caller that forgot
it](079-a-forgotten-lane-cannot-be-reclaimed.md) asks who may close a lane nobody
has stopped naming. This asks something its measurements cannot reach: **when
the callers are a fleet, should the ceiling be a property the server enforces,
or may it stay a convention each caller is asked to keep — given that the caller
which leaks is a subagent, and the only thing it ever receives is the prompt its
parent wrote?**

079 already records the shape of the failure from one session's seat: twelve
lanes, `40 open, 1 orphan`, three callers, one closable tab. What is new here is
the *ceiling*, and the fact that the leak survived being told not to happen. The
sibling agents on 2026-09-28 were not left unsupervised: they were handed
`using-passenger` and, in the same brief, the sentence it already carries — *"a
`script` with no `tab` opens a fresh one every call"*. They read it. It did not
bind, twice, in parallel.

## What was measured, 2026-09-28, ~16:43 local

Two subagents and this session, three `script` callers, one shared Chrome on the
owner's 30 GiB machine. The session had opened a lane only to run
`showBrowser`; the leaking was the two siblings'.

- `browser_status` mid-incident: `49 open, 0 orphan`, `wedged: 1 silent`.
  **This number was in front of the caller and meant nothing** — it is a count,
  it says nothing about whose, and 49 does not read as a problem.
- `/json/list`: **137 targets, 46 of them `page`**. The two counts disagree
  because they count different things; neither is wrong and the gap is not
  explained here.
- `ps`, sampled twice ~30s apart: **98 then 100 chrome processes, 26.6 then
  26.8 GB RSS total.** By type: `renderer` 83 procs / 25.4 GB, `gpu-process` 2 /
  462 MB, `utility` 5 / 421 MB, `zygote` 6 / 249 MB.
- Eleven renderers were at or above ~474 MiB, the largest at **1.74 GiB**. Which
  URL owned which renderer was **not** established — do not read the page list
  below as an attribution.
- Machine state: `Mem: 30 GiB total, 27 GiB used, 3.0 GiB available`; swap
  already **6.5 GiB of 32 GiB spent**; **load average 50.64**. The owner noticed
  before the agents did, and reported it as *"memory/CPU is blowing up"*.
- The open pages were the ones a research task actually wants: Facebook group
  feeds, Reddit, Xiaohongshu search, Wayback snapshots, three Discuz forums.
  Heavy SPAs, each fetched once, each left standing.

**Clearing it, for the record:** killing all 46 page targets over CDP — not the
browser — took chrome from 26.8 GB to 8.3 GB and `available` from 3.0 GiB to
14 GiB, without touching the profile. `destroyLane` was never usable here: the
siblings' lanes were nameable only by the siblings, and one of them (§Adjacent)
was not the build the caller thought it was talking to.

## Adjacent finding — this belongs in its own ticket

Found while diagnosing the above, and it is a different bug. Two passenger
builds were live at once: the long-lived `Watchdog.res.mjs` (pid 767377, started
14:39) came from nix store path `nl5sv3463…`, while this session's four
`Main.res.mjs serve` processes (started 16:30) came from `ryzq6yviv1…`. The
store held **six** `passenger-0.1.0` derivations. Nothing errored; the only way
to see it was to read `/proc/<pid>` for every passenger process and compare
store paths. The remedy was kill everything and reconnect, after which exactly
one build was in use.

A daemon that outlives the build that produced it, and keeps serving clients
from the new build, is worth its own question — at minimum, whether it can
notice and stand down. Filed here only so the measurement is not lost.

## What this is not

- **Not a duplicate of 079, and not its rival.** 079 asks how a caller reclaims
  what it forgot. 080 asks whether a ceiling should exist at all. If 079 lands
  its direction 3 — *do not mint a tab* — then this ticket should close as
  answered, and says so below. The honest relationship is that **this ticket is
  evidence for 079's direction 3**, gathered from callers that had been told.
- **Not [why the passenger Chrome drains the
  battery](078-chrome-power-usage.md).** That is watts. This is 3 GiB of free
  memory on a machine that also has to compile.
- **Not a claim that the anti-throttling flags are the cause.** They plausibly
  raise the cost of a background tab; they do not create the 46th one.
- **Not measured:** per-tab byte attribution, the cliff between 49 tabs and
  swap exhaustion, or how much of the 26.6 GB a *single* sibling was
  responsible for. Three callers shared one number and nobody split it.

## Directions, none of them costed

1. **Nothing, and lean on 079.** If "do not mint a tab" lands, the fleet case
   dissolves — the 46th tab is never created, so no budget is needed. To take
   this, say what happens to the callers that *want* a second tab, and whether
   `Page.goto` into a reused tab is acceptable for the research pattern above.
2. **A budget the daemon refuses to exceed.** Past N tabs or N gigabytes, the
   next `script` fails with a named error instead of succeeding. This is the
   only direction that makes the ceiling a property. Costs: picking N, and
   deciding what a mid-task agent is supposed to do when it is told.
3. **Attribution that the *parent* can read.** 079's direction 4 scoped it to
   the leaker. Under a fleet that is the wrong reader — a subagent stopped at a
   ceiling cannot explain what it was doing, and its prompt is the only channel
   back. Whether the fleet dimension is enough to revise 040's "a count, not a
   listing" is the open part.
4. **Charge the tab to the caller that asked for it, and reap on idle within
   the lane.** Not the lane TTL — a per-tab idle clock, so a page read once and
   abandoned goes away without the lane having to be named by anyone. Roughly:
   [the idle reap](077-build-idle-reap.md) at tab granularity rather than lane.
   This is the one that would have saved the 46 without any caller changing.

## Constraints

- **The machine is the human's, and it is not idle.** 30 GiB total, and on the
  same box a separate session was running `dotnet` conformance builds. The
  server's worst case has to be a number the owner can live with, not merely one
  an agent can survive. Nothing here should assume it owns the host.
- **Stealth and the warm session are still the product**, unchanged from 079:
  no distinguishable browser, no discarding the logged-in profile to buy
  isolation.
- **The reader is a subagent, and the human cannot see it.** Whatever is
  written must work when the reader is a prompt written by another agent, and
  when the leaking process cannot be interrogated afterwards. Prose has been
  tried and lost twice on the same day; a third attempt needs to say why it
  would fare differently.
