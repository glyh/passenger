---
id: 004
title: Reaching content that sits behind an interaction
labels: [wayfinder:research]
status: open
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
