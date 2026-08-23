---
id: 018
title: Asking for a human, rather than being guessed at
labels: [wayfinder:task]
status: closed
assignee: glyh
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
   it. The answer is now no -- see [The tool does not learn; the agent
   remembers](019-the-tool-does-not-learn.md), which this blocks. What
   the caller needs is not a way to write into `signatures.json` but a
   way to act on what it already recognised, which is what this ticket
   is. Where the knowledge goes afterwards is the agent's memory.
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

## Answer

`show_browser` grew the wait. No eighth tool, and nothing here decides
whether a challenge was solved.

    show_browser(tab=None, wait_seconds=0, notify_human=False) -> str

**1. The shape.** A `handoff` verb was rejected against [How thin can this
layer get](020-how-thin-can-this-layer-get.md)'s finding that seven tools
is the floor. So was building nothing: the composed version --
`show_browser` then a polling `script` -- does work today, and it is what
the docstring now tells the agent to do, but it cannot bring the right tab
to the front and it cannot wait on the human rather than on the page.
Those two are what `show_browser` gained, and both are things the caller
genuinely could not reach.

**2. What ends the wait.** The human closing the viewer, or the budget; the
return says which, and never says "solved". Every page-side signal was
rejected as the same guess [The extract mode decides whether a page counts
as blocked](005-mode-decides-blocked.md) deleted, made again on weaker
evidence: `classify` re-checking is meaningless when nothing matched to
begin with, a word-count threshold is that ticket's tier walking back in,
and a URL change misses the Cloudflare interstitial that clears by
reloading the same address. The agent polls the page, because the agent
recognised the wall in the first place -- which is the whole competence
this ticket credits it with. That is [The result says what it did not
reach](016-the-result-says-what-it-missed.md) one ticket later: reading the
page is the caller's job.

`presented()` is a real observation only for the local presenter --
`LinkPresenter` and `NullPresenter` answer `False` unconditionally, because
whether anyone opened a URL handed to them is unknowable from here. A
presenter that cannot see its own window now *refuses* the wait and says to
poll, rather than reporting the viewer closed the instant the wait begins.

**3. Teaching a novel challenge.** No, per [The tool does not learn; the
agent remembers](019-the-tool-does-not-learn.md), which this unblocks. The
docstring carries the boundary: *whatever you learn about the site is worth
remembering; this tool will not remember it for you.*

**4. The signature handoff stays.** `fetch(wait_seconds=…)` and
`handoff.wait_for_human` are untouched, and `--handoff` keeps its default.
It is a second way to wait for a human, kept because the signature case is
the one place a completion signal genuinely exists -- a Turnstile frame no
longer in the DOM is a fact, not a threshold -- and because 020 kept `fetch`
itself on the reasoning that the common case should cost no code. The two
paths compose rather than compete now that `Blocked` names its tab.

**5. Present and wait are separable.** 010's question 3, answered yes:
`wait_seconds=0` is the whole of the old behaviour, and the wait is
reachable on a browser that is already visible.

**6. The unattended caller.** 010's question 4, answered by the same move as
`notify_human`: the agent knows whether a person is watching, and this side
cannot. An explicit parameter rather than an inference from `wait_seconds`,
defaulting to silence -- the common case is an agent mid-conversation that
is about to say the same thing in its reply, and a `notify-send -u critical`
on top of that is the tool talking over the agent. A cron job sets it and
the webhook reaches someone.

### What the field cost

`Blocked` gained `tab`, which `Ran` and `Failed` always carried. Without it
an agent that wanted the deliberate path had to `list_tabs` and match on a
URL. Adding it exposed that the field would have been a lie: `fetch` blanks
its tab on the way out unless `keep_tab`, so the record would have named a
tab the wall had just been navigated off. A blocked outcome now keeps its
tab whatever `keep_tab` says -- it is the one outcome whose tab the caller
still needs.

Measured: `fetch https://github.com/login` returns
`blocked/login-wall` naming tab `306B4F2C…`, and that tab is still on
`https://github.com/login` afterwards.

### Not done here

The CLI is deliberately left behind -- no `--tab` on `show`, no wait, no
notify. Mirroring three flags by hand is the symptom, not the fix; see [One
description, two doors](026-one-description-two-doors.md).

Tests: `tests/test_handoff.py`, three cases, all on the refusal branch and
the two wait endings. The scar is the design one -- a wait built on
`presented()` reports success immediately on exactly the deployments that
most need a human.
