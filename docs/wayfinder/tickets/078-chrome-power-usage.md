---
id: 078
title: Why the passenger Chrome drains the battery
labels: [wayfinder:research]
status: closed
assignee: lyh (via Claude)
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

## Answer

Measured on the owner's laptop (Intel Core Ultra 7 258V, 8 cores, 48.8 Wh
battery, **on battery** for the whole run) on 2026-10-06, 12:47–13:23.

**Suspect 1 is the answer, and it is exactly one of the three flags.** Six tabs
doing ~3 ms of work per 50 ms tick — the shape of an animated or polling page —
cost **+0.65 of a core, +1.2 W on the CPU package and +0.6–1.2 W at the
battery** with the hidden launch's flags in place, because their timers fire at
**20.05/s instead of 0.65/s** (31x). `--disable-background-timer-throttling`
alone reproduces the entire cost; the other two flags reproduce the free case
exactly, and in this nested-headless setup they do nothing measurable at all.

**A warm session holding a static tab is free.** The 65-hour Chrome that was up
when the run started, one tab (`jiangmen.ke.com`), 120 s: battery energy
**9.9 W** (power_now mean 9.41) against baselines of **10.5 W** and **8.1 W**
with no Chrome at all — inside the noise. Its own CPU was 8.9 CPU-s over 120 s,
**7.4% of one core** (renderer 5.1, gpu 2.05, browser 1.68, utility 0.07,
zygote 0.01), and **sway 0.31 + wayvnc 0.00 CPU-s over the same 120 s**. The
report's drain is not this state, and the flags do not cost anything by
themselves: they remove the ceiling that would otherwise cap a *busy* page.

### How, and why the rig exists

- Windows of 60–120 s, one state each, whole-system watts from the battery's
  own `energy_now` counter (µWh; it steps every few seconds, so a 60 s window
  resolves ~36 J ≈ 3%) cross-checked against `power_now` sampled every 2 s, and
  CPU package/psys from RAPL (`sudo -n cat /sys/class/powercap/intel-rapl:{0,1}/energy_uj`,
  mode 0400 on this box). CPU-seconds per process from `utime+stime` in
  `/proc/<pid>/stat`, classified by role from `cmdline`.
- The first sweep (S1–S4, above and below) ran against the **shared** browser.
  Halfway through it, **a second caller appeared**: another pi session's
  `passenger serve` (pid 1609914, parented to a pi started 12:15) launched its
own Chrome at 12:55:21 and loaded a page of its own. That is 080's fleet,
  observed live, and it means nothing measured on the shared browser is
  attributable to one caller.
- So the flag question was measured in an **isolated rig**: its own sway
  (`WLR_BACKENDS=headless`), its own profile, its own CDP port (9333), its own
  page server, all under `/tmp/power`. It launches through the **same generated
  `session.sh` the tool writes** (`render.sh` rewrites the state paths and the
  port, nothing else), so the only difference between variants is argv.
- The readout is the pages' **own tick count**: each of six pages runs a 50 ms
  timer doing ~3 ms of real work, counts its ticks and its rAF callbacks, and
  reports them to a local server. The rate is therefore evidence, not an
  inference from CPU time. `ABBA` ordering, and a discarded warm-up launch so
  the first measured window is not the one paying for a fresh profile.

### The numbers

| window | timer ticks/60 s | rig Chrome CPU-s/60 s | pkg W | core W | batt W |
|---|---|---|---|---|---|
| flags **with** (3 windows) | **7218, 7218, 7218** = 120.3/s | 51.3, 55.6, 51.5 → 85–93% core | 6.89\*, 4.65, 5.79 | 2.69\*, 1.73, 2.07 | 11.39\*, 7.79, 8.99 |
| `--disable-background-timer-throttling` **only** | **7218** = 120.3/s | 53.2 → 88.6% core | 5.29 | 2.09 | 7.79 |
| the two occlusion flags **only** | **1398** = 23.3/s | 12.8 → 21.4% core | 8.83\* | 3.61\* | 12.59\* |
| flags **without** (3 windows) | **1403, 1398, 1398** = 23.3/s | 14.6, 14.5, 14.0 → 21–24% core | 4.05, 4.00, 5.44 | 1.28, 1.25, 1.88 | 6.59, 7.19, 8.99 |
| no Chrome, no sway, no wayvnc | — | — | 6.09, 4.37 | 2.17, 1.47 | 10.5, 8.1 |
| first 60 s after launch | 7218 | 52.5 → 87.5% core | 5.76 | 2.25 | 8.39 |

`*` = that window overlapped unrelated load on the machine (load average 4.7–5.1,
total CPU 20–26%): its battery and package figures are contaminated and are not
used below. Every other pair is same-run and back to back.

- **Core cost**: 88.6% − 21.4% = **+0.67 core** (timer-only vs occlusion-only,
  one after the other).
- **Package cost**: 5.29 − 4.00 = **+1.29 W**; by medians 5.29 vs 4.05 =
  **+1.24 W**. ≈ 2 W per busy core, which is the right order for this chip.
- **Battery cost**: 7.79 vs 6.59/7.19 = **+0.6 to +1.2 W**, i.e. 8–15% of a
  7–8 W idle laptop. The battery counter does not resolve this reliably on a
  machine with other agents on it (see the noise floor below); the package
  counters do.
- **Scale, stated so it is not over-read**: the per-tick work is a chosen 3 ms.
  The finding is not "the flags cost 1.2 W", it is "the flags multiply a
  background tab's timer rate by 31 and its CPU by 3.7". A page doing 0.3 ms
  per tick would make the same six tabs ~0.1 core; an ad-heavy page doing more
  would make them several cores. At 080's 46 tabs the multiplier is the whole
  mechanism, and the only bound on it is the TTL.

### Suspect by suspect

1. **The three anti-throttling flags — confirmed, and attributed.** One flag of
   the three. Cost is real but proportional to what the tabs do; the flags
   themselves are free.
2. **The headless compositor — not it.** sway 0.31 and wayvnc 0.00 CPU-s over
   120 s, and no resolvable watt difference between S1 (compositor + browser up)
   and S2/S3 (nothing up) once the noise floor is admitted. No viewer was
   attached in the rig, so **wayvnc encoding to a real client is not measured**.
3. **Tabs outliving their use — the multiplier, not the cost.** Confirmed as the
   thing that makes the flags matter; see the scale note.
4. **GPU / rasterisation — not answered.** This box exposes no RAPL GPU domain,
   so the GPU process's watts are inside the package figure and cannot be split
   out. `session.log` shows `--render-node-override=/dev/dri/renderD128` and a
   real render node, so the session is on the hardware GL path, not SwiftShader
   — but that is a log line, not a measurement.
5. **The watchdog and the serve processes — negligible, confirmed.** Every
   passenger server process on the machine together accounted for 0.1–1.8
   CPU-s per 120 s (<2% of a core).
6. **The profile — a memory cost, not a power cost.** The real profile's idle
   Chrome ran 11 renderer processes / 1790 MB (most of them `--extension-process`)
   for 5.1 CPU-s per 120 s; the rig's fresh profile ran 8 renderers / 1093 MB
   with six busy pages. Extensions cost RAM and almost no CPU.

### Stealth: the flag is observable by the page itself

Measured per tab, with and without the flags (same six pages, `visibilityState`
reported by each page alongside its own rate):

| | visible tab | the five hidden tabs |
|---|---|---|
| flags **with** | `visibilityState='visible'`, 20.05/s | `'hidden'`, **20.05/s** |
| flags **without** | `'visible'`, 20.03/s | `'hidden'`, **0.65/s** |

A page can see both halves of this: it knows it is hidden, and it can measure how
often its own timers fire. **Hidden-but-unthrottled is therefore a fingerprint**
any analytics or challenge script can take for free, and it is the flag that
keeps challenge scripts alive off-screen that creates it. Removing the two
occlusion flags costs nothing measured and shrinks argv; removing
`--disable-background-timer-throttling` would be stealth-*positive* but is the
flag doing the job it was added for. That tension is the follow-up ticket's, not
this one's.

rAF ran at **60.1/s in every variant**, including with the flags removed, and
only in the visible tab (hidden tabs: 0.00/s). Under headless sway Chrome never
learns the window is occluded, so `--disable-backgrounding-occluded-windows` and
`--disable-renderer-backgrounding` had nothing to do — which is a fact about
this compositor, not a law: on a compositor that does report occlusion they
would be load-bearing again.

### Found on the way

- **Closing the last page target ends the whole session.** The S2 window's
  `close_all` closed the one tab, Chrome exited, `session.sh`'s `wait` returned,
  `swaymsg exit` ran and wayvnc died with it. "Close the last tab" is not "close
  a tab" — it is teardown of the compositor and the VNC endpoint. Relevant to
  079/080: a reap that closes every tab of a lane takes the session down.
- **A second caller on the machine, live.** Another pi session's server started
  its own Chrome on the shared profile mid-sweep (above). Two callers, one
  browser, no attribution — 080's premise, measured rather than argued.
- **Starting the browser is energy-free.** The first 60 s after launch
  (8.39 W, pkg 5.76) is indistinguishable from a settled window (7.79 W, pkg
  5.29); the difference is ~0.5 W for ~60 s ≈ **0.01 Wh**, ~0.02% of the
  battery. 081's "a fresh Chrome every 45 minutes" costs nothing to run.

### The noise floor, and what is not measured

- **±1.2 W at battery level while the machine is in use.** Two baseline windows
  with nothing of ours running gave 10.5 W and 8.1 W; the same rig variant
  repeated gave 6.59 W and 7.19 W. The package counters were far tighter (the
  "without" pair: 4.05/4.00 W, core 1.28/1.25 W), which is why the conclusions
  above rest on them. On a machine that is not idle, a 1 W claim cannot be made
  from the battery counter in one window.
- **Not measured**: GPU watts; real ad-heavy pages under the flags (the rig page
  is a deliberate proxy with a known per-tick cost); the 46-tab aggregate 080
  saw; wayvnc encoding with a client attached; and any of it on a machine that
  is otherwise idle.
- **Rerunning it**: the sampler, `render.sh`, `busy.html` and the two rig
  drivers are in `/tmp/power` — scratch, uncommitted, and regenerable from the
  description above. The recipe is small enough to keep in a shell history:
  battery `energy_now` (µWh, ×3.6e-3 → J) twice 60 s apart; RAPL
  `intel-rapl:{0,1}/energy_uj` (root) for package/psys; `utime+stime` from
  `/proc/<pid>/stat` for per-process CPU.

### What a fix would have to be, and where it belongs

The numbers say three things about the follow-up. **The two occlusion flags can
probably go** — measured inert here, one line of argv, no behaviour change
observed — but the reason they are inert is this compositor, so that needs a
sentence of justification rather than a deletion. **The timer flag cannot simply
be dropped**: it is the one keeping a hidden tab's challenge script awake, and
dropping it is the one change that is stealth-positive but behaviour-negative.
**What the numbers do support is scoping it per tab rather than globally** —
lift throttling for the tab a `script` call is touching and leave the other
forty-five throttled — which is the ticket's own to-decide 3, now with a price
on both sides of it. Failing that, the multiplier is bounded only by how many
tabs are left standing, which is 079 direction 3 and 080 direction 4, and this
measurement is one more argument for both.

### Addendum, 13:34 — the test the fix rests on, run and passed

The per-tab scoping above depends on one thing nobody had measured: does
*activating* a background tab lift its throttling? No flags anywhere in this
run; `GET /json/activate/<id>` is the HTTP spelling of `Target.activateTarget`,
which is what Playwright's `page.bringToFront()` sends, so this tests the call
the fix would make rather than a stand-in for it.

| window | the active tab | the five hidden tabs |
|---|---|---|
| as launched | page 1: **20.02/s**, `'visible'`, rAF 60.1/s | 0.57/s each, `'hidden'`, rAF 0 |
| after activating page 3 | page 3: **20.00/s**, `'visible'`, rAF 60.0/s | page 1 falls to 0.93/s and `'hidden'`; the rest 0.02/s |
| after re-activating page 1 | page 1: **20.02/s**, `'visible'` | page 3 falls to 1.00/s, `'hidden'` |

Activation moves the one unthrottled slot exactly where it is needed, and it is
reversible. The escalation is visible in the same data: a tab hidden for minutes
sits at 0.02/s where a freshly hidden one sits at 0.57/s.

So the fix is buildable as described: **`page.bringToFront()` in the attach
path, and the three argv entries in `Browser.res`'s `hidden` branch deleted.**
What that leaves is at most one unthrottled tab per browser — the one in front,
which is what a human's daily driver looks like — and no hidden-but-unthrottled
tab for a page to notice. It does not replace 079/080: the *active* tab still
runs unthrottled if a caller walks away, so this caps the multiplier at one tab
while those tickets cap the tab count.
