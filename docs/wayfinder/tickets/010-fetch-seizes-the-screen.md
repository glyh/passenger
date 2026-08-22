---
id: 010
title: A fetch of an ordinary page put the browser on screen and waited
labels: [wayfinder:task]
status: open
assignee:
blocked_by: []
---

## Question

    agent-browser fetch https://example.com

with no flags, on the plainest page on the internet: the nested browser was
presented on the user's desktop, a notification fired, and the command blocked
for the full 300-second handoff timeout before returning anything.

Nothing was in the way. `example.com` is thirty-odd words of boilerplate --
that is what the page *is*. `min_words` defaults to 80, so `classify` returned
a `NovelBlocker`, and `_resolve` treats every blocker the same: `allow_handoff`
is `True` by default on the CLI (`ab/cli.py:35`), so the response was to seize
the screen and wait for a human who had not asked to be involved.

Note that the MCP server already has this right. It gates the handoff on
`wait_seconds > 0` (`ab/mcp_server.py:74`), so an agent has to ask for the
possibility of interruption before it can happen. The CLI opts in for you.

The asymmetry is the heart of it. The two verdicts are not equally strong:

- A `KnownBlocker` means a signature matched -- a Cloudflare frame, a
  reCAPTCHA iframe, a `/login` URL. That is specific, positive evidence that a
  human is genuinely required, and presenting the window is the right and
  designed-for response.
- A `NovelBlocker` means only *this page had fewer words than a number I was
  handed*. It is the weakest evidence the system produces, it fires on every
  legitimately short page, and it currently triggers the single most intrusive
  action the tool can take.

The cost is not just the interruption. A `fetch` that blocks for five minutes
is a `fetch` that returns nothing for five minutes -- to a script, to a shell
pipeline, to anything running unattended. `was_hidden` does mean the window is
dismissed in the `finally`, so the desktop is restored; it is restored after
the timeout, which is not the part that hurt.

This is the same soft spot ticket [The extract mode decides whether a page
counts as blocked](005-mode-decides-blocked.md) probes from the other side.
005 asks whether a thin page should be *called* blocked; this asks what the
tool should be allowed to *do* on the strength of that call. Fixing 005's
corroboration point would make novel verdicts rarer without changing the fact
that, when one does fire, the reflex is to take over the screen.

To decide:

1. Whether a novel verdict should be able to trigger a handoff at all, or
   whether presenting the window should require a `KnownBlocker`. The
   conservative version -- known blockers present, novel blockers return
   `Blocked` with the evidence and hint that already exist -- costs a real
   handoff only in the case where a genuinely new challenge appears, which is
   also the case where the proposed-signature machinery wants a human anyway.
2. Whether the CLI's `--handoff` should default to `False`, matching the MCP
   server's opt-in. Interrupting a person is an escalation; escalations should
   be asked for.
3. Whether "present the window" and "wait for the page to change" should be
   separable. Polling until a block clears is useful with the browser already
   visible -- the user may be solving something in a window they opened
   themselves -- and does not require this side to grab focus.
4. What an unattended caller should get. There is no signal today that
   distinguishes a terminal a human is watching from a cron job, and the
   answer for the two is different.
