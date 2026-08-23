---
id: 018
title: Asking for a human, rather than being guessed at
labels: [wayfinder:task]
status: open
assignee:
blocked_by: []
---

## Question

[The extract mode decides whether a page counts as
blocked](005-mode-decides-blocked.md) removed the tier that guessed a
page was blocked from its word count. That was the right removal, and it
leaves one thing genuinely unreachable.

A challenge from a vendor with no signature yet now comes back as thin
content. A caller looking at 30 words of "verify you are human" can see
perfectly well what it is -- and has no way to act on it. `wait_seconds`
on the MCP door and `--handoff` on the CLI both only do something once
`classify` has *already* decided the page is blocked, so the one path to
a human is gated behind the judgement that was just deleted.

Note this is not a regression to argue away. The old path summoned a
human for every short page and got a genuinely novel challenge right by
accident, at the cost of interrupting on `example.com`. What is wanted
is the same destination reached deliberately.

To decide:

1. The shape. A `handoff` verb that presents the window and waits on a
   tab the caller names is the obvious one, and it composes with 013 --
   the caller already has a tab id, and `script` already reads the tab a
   human just used. That may mean this is a thin wrapper over `show`
   plus a poll, rather than anything new.
2. What "solved" means with no signature to re-check. `wait_for_human`
   polls until `classify` stops matching, which is meaningless when
   nothing matched to begin with. Candidates: the URL changed, the word
   count moved, or simply the human says so by the call returning when
   they dismiss the window.
3. Whether a caller that met a novel challenge should be able to *teach*
   it -- a signature added deliberately, from a page a human confirmed
   was a challenge, is the good version of what `propose_signature` was
   doing badly. The registry's curation half (`pending_review`,
   `approve`, `forget`) survived 005 intact and is sitting there unused.
4. Whether the CLI keeps `--handoff` on by default once the only trigger
   is a signature match. 010 left it alone deliberately; worth
   revisiting beside a deliberate verb.
5. Whether presenting the window and waiting for the page to change should
   be separable. Polling until a block clears is useful with the browser
   already visible -- a human may be solving something in a window they
   opened themselves -- and does not require this side to grab focus.
   Carried from [A fetch of an ordinary page put the browser on screen and
   waited](010-fetch-seizes-the-screen.md), question 3.
6. What an unattended caller should get. Nothing distinguishes a terminal a
   human is watching from a cron job, and the right answer differs: with a
   signature match as the only trigger the interruption is at least
   deserved, but a cron job still blocks for the full timeout with nobody
   there. Carried from 010, question 4.
