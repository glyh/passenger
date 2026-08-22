---
id: 004
title: Reaching content that sits behind an interaction
labels: [wayfinder:research]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

`fetch` is `goto` then read. Every page whose content is reachable only
by *doing* something first -- typing in a search box, clicking a tab,
paging a result list -- is therefore out of reach, however well the
session is authenticated and however cleanly the challenge was solved.

The case that surfaced it: `ratchakitcha.soc.go.th`, the Thai Royal
Gazette, checked for whether a visa reform had been published. The
Cloudflare interstitial was handed off and solved by the human, and the
site then rendered perfectly -- 2,109 words through `dom`. But its search
is JS-driven: `?keyword=<thai>` does not survive into the query, and
every URL variant tried (`searchType`, `page`, the `/search` →
`/search-result/` redirect) returned the unfiltered set of all 1,286,739
records. The backing API answers 403 to `curl`, because the cleared
challenge lives in the browser profile and nothing but this tool can
reach it. So the one client that *could* run the search was the one that
cannot type into a box, and the fallback was paging a date-ordered list
of roughly a hundred bankruptcy notices at a time.

Note the shape: the handoff already puts a human at the keyboard, in a
real browser, on the right page. They could have typed the keyword in
two seconds. There is no way to then read what they navigated to --
`fetch` would `goto` the URL again and throw their navigation away.

Decide how far up the Playwright surface this tool should go.

1. **Is the cheap fix sufficient?** A read of the *current* page --
   `fetch` with no url, or a separate `read_current` -- adds no
   automation surface at all, and closes the case above by leaning on the
   human who is already there. It also gives the handoff path something
   it lacks: a way to see the result of a solve that involved navigation
   rather than just a checkbox.
2. **Or the full surface?** `click`, `fill`, `press`, `select`, `scroll`,
   `wait_for` -- addressed how? Selectors are brittle and the agent
   cannot see the page to choose one; accessibility-tree addressing, or
   a numbered-elements snapshot, are the two usual answers and they are
   very different amounts of machinery.
3. **State across calls.** MCP tools are individual calls; an interaction
   sequence needs a page that persists between them. `reuse_tab` already
   keeps one tab, but nothing addresses *which* tab, and `keep_tab` /
   `close_tabs` were designed for a one-shot fetch. What is the handle,
   and what happens when it goes stale mid-sequence?
4. **Where detection runs.** `classify` currently runs once, after the
   single navigation. In a sequence, a challenge can appear at step four.
   Does every step probe, or only reads?
5. **Whether driving the page costs the thing the tool is for.** The
   premise is a browser sites cannot distinguish from an ordinary one.
   Synthetic clicks with no plausible pointer path, and fills with no
   keystroke timing, are among the signals anti-bot systems actually
   look at. A tool that automates its way into a block it would not
   otherwise have hit has made itself worse, so the honest answer might
   be that (1) is not a stepping stone to (2) but a deliberate stopping
   point.

## Research so far

Findings: [What driving the page would cost, and what it would look like](../assets/004-driving-the-page-findings.md).

**The direction is set, and it is neither of the two options above.** Not a
rewrapped verb per action (question 2), and not a stopping point at reading the
current page either: expose the Playwright surface *directly* -- one way in
that can call any API `page` exposes -- with this project's scaffolding
wrapped around the call rather than around each verb. Rewrapping is the thing
being avoided; the peers' addressing schemes (accessibility refs, coordinates)
exist to serve a per-verb tool surface that this design does not have.

That answers questions 1 and 2 and rewrites what is left:

- **The envelope, not the verbs.** What the script is written against
  (`page`), what may cross the MCP boundary (JSON only -- handles cannot),
  and whether the reply carries an extraction of the page the script left on
  as well as the script's own return value.
- **Question 4 gets easier, not harder.** Running the existing probe/classify
  on the page the script *ends* on yields the same `blocked` outcome the agent
  already knows how to handle, whatever happened in between. No per-step
  probing needed.
- **Question 3 got sharper.** Probing for it surfaced
  [One wedged tab bricks every later call](012-one-wedged-tab-bricks-every-call.md):
  a tab left mid-navigation hangs `connect_over_cdp` indefinitely. A driving
  sequence keeps tabs alive across calls by design, so the handle needs a
  liveness story, not just a name.
- **Patchright's isolated world leaks into the design.** `evaluate` defaults
  to `isolated_context=True`; page globals are invisible unless the caller
  opts out, and opting out is the detectable path. Measured.
- **Question 5 is answered on the evidence, and does not block the shape.**
  Every CDP-dispatched event is `isTrusted: true`, so the flag is not the
  tell. `click` teleports the cursor -- one `mousemove`, at the destination --
  and `fill` emits a bare `input` with no keystrokes at all. Against
  continuous behavioural scoring (Cloudflare Precursor and its kin), that is
  what gets a warm profile marked. It does not argue against a passthrough;
  it argues that reading and driving are different *kinds* of act, and that
  the difference has to be stated where the caller reads it.

Still open: whether the script is Python or JS; what the tab handle is; what a
sequence looks like across several calls; and whether execution of caller-
supplied code in the MCP server process needs any boundary beyond the one the
agent already has (it can run `Bash`).

## Answer

**All the way up -- but through one door, not a door per verb.** A single
passthrough tool that runs caller-supplied Python with `page` bound, so the
whole patchright surface is reachable without this project rewrapping any of
it. The scaffolding wraps the *call*, not each verb.

The envelope:

- **The script** is Python source, executed with `page` (a patchright sync
  `Page`) and `read(page)` -- the project's own extraction -- in scope. Control
  flow, waits and locals across statements come for free, which is the whole
  reason not to take a step list instead: a declarative `{method, args}` list
  would have been a rewrapping too, just a generic one, and would still have
  had no handles between steps.
- **What crosses back** is the script's return value, JSON only. A Playwright
  handle cannot cross an MCP boundary; returning one is a typed error that
  names that, rather than a serialisation traceback.
- **The page it ends on** is probed and classified by the existing
  `probe`/`classify`, so a challenge that appears at step four comes back as
  the same `blocked` outcome `fetch` already returns and the agent already
  knows how to act on. That is question 4 answered by construction -- no
  per-step probing. The accompanying extraction is opt-out, because a
  sequence that pages a list should not pay a full page read per step.
- **The tab** is addressed by CDP `targetId`. Every reply carries the id of
  the page it ended on; a later call passes `tab` to resume there, and a
  listing (id, url, title) names what is open -- which is what makes the
  motivating case work at all: after a handoff, the agent finds the tab the
  *human* navigated to and reads it. A stale id is a typed error, and the
  reap from
  [One wedged tab bricks every later call](012-one-wedged-tab-bricks-every-call.md)
  is what keeps a dead tab from taking the next attach down with it.
- **No `read_current` tool.** The ticket's option 1 was to add one; it is not
  needed, because `{tab: <id>, script: "return read(page)"}` *is* it. One tool
  covers both the cheap case and the expensive one.
- **Executing caller-supplied code** adds no privilege boundary that is not
  already open: the MCP server runs as the user, and the agent calling it has
  a shell. Pretending otherwise by sandboxing the script would cost more than
  it buys.

**On question 5, the honest part.** Measured (see the findings asset): every
CDP-dispatched event is `isTrusted: true`, so nothing here is detectable by
that flag. But `click` teleports the cursor -- one `mousemove`, at the
destination -- and `fill` emits a bare `input` with no keystrokes at all, and
continuous behavioural scoring is exactly what watches for that. So reading a
page a human navigated to and driving one are different *kinds* of act:
reading emits no behavioural signal, driving spends the reputation of a
profile whose value is that it has never done anything unusual. The
passthrough permits both and says so where the caller reads it; it does not
pretend they cost the same.
