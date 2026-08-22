---
id: 013
title: The passthrough tool that runs a script against a page
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

Build what
[Reaching content that sits behind an interaction](004-driving-the-page.md)
decided: one MCP tool that runs caller-supplied Python with `page` bound,
addressed by CDP `targetId`, with the existing probe/classify run on the page
the script ends on.

Blocked by
[One wedged tab bricks every later call](012-one-wedged-tab-bricks-every-call.md):
this tool keeps tabs alive across calls by design, so shipping it on an attach
that hangs forever on a stale tab would make that defect routine rather than
occasional.

The design is settled; what remains is the work and the small decisions inside
it:

- Where it lives. `service.fetch` is the one orchestration today, and this is
  a second one that shares its tail (extract, probe, classify, the `Fetched` /
  `Blocked` union). Whether the shared tail becomes its own function or the two
  entry points converge on one request model.
- What `read(page)` is, exactly -- the `Extraction`, or the `Fetched` shape.
- How the script's return value is validated as JSON before it crosses, and
  what the error says when it is a handle.
- Whether the CLI gets the same door, or this stays MCP-only.
- Timeouts: a script can loop. Per-call wall clock, and what a timeout leaves
  behind.
- The tool description carries the reading-vs-driving distinction from 004,
  in the place the agent actually reads.

## Answer

Built, as `script` on the MCP server and `agent-browser script` on the CLI.
The measured proof it does what the ticket was opened for: a script typed
"web scraping" into Wikipedia's search box, pressed Enter, waited, and came
back with `returned: "…/wiki/Web_scraping"` and the article extracted at 4,438
words -- content a `goto` of the original URL could never have reached.

On the decisions the ticket left open:

- **Where it lives.** The shared tail became `service.inspect(page, mode,
  min_words)`, returning the extraction and the blocker: `fetch` runs it once
  after its navigation, `run` runs it on whatever page a script ends on. The
  request models stayed separate, and that turned out to be the informative
  part -- a `ScriptRequest` has no url, no `wait_until`, no `settle_ms`, no
  handoff, because a script decides its own arrival. Converging them would
  have meant a model whose fields are half-meaningless at either door.
- **What `read(page)` is.** The markdown string. It is bound into the script's
  scope, so `return read(page)` is the whole of the read-current case that
  ticket 004 had considered giving its own tool.
- **What may cross.** `json.dumps` is the gate, and the error names the type:
  "a Locator cannot cross the tool boundary -- return what you wanted from it
  instead: page.url, locator.inner_text(), read(page), a list of hrefs". That
  matters because nearly every Playwright call hands back a handle, so it is
  the obvious mistake, and a serialisation traceback would not say what to do.
- **The CLI gets the same door.** `agent-browser script` reads the script from
  a file or stdin, which makes it a heredoc away from a terminal, plus
  `agent-browser tabs` to see the ids. Parity was cheap: both frontends are
  thin over `service.run`.
- **Timeouts, honestly.** `timeout_s` becomes the page's default timeout, so
  every Playwright call inside the script is bounded and a wait on a selector
  that never appears ends the call rather than the session. A script that
  loops without calling Playwright is *not* interruptible; that is the limit
  of running code in-process, and the docstring says so rather than implying
  a wall clock that does not exist.
- **Failure is an outcome, not an exception.** `failed` carries the error, the
  offending line *numbered against the caller's own source* (the wrapper line
  is subtracted), and the state of the tab, because the next move is to fix
  the script and call again. Measured: a bad selector reports `line 2:
  page.click("#no-such-thing", timeout=2000)` and exits 2 on the CLI.
- **The description carries the distinction.** The server's instructions now
  say to prefer reading over driving, and why: after a human has navigated,
  reading their tab is invisible to the site, where synthetic clicks and fills
  have no cursor path and no keystroke timing -- which is what behavioural
  anti-bot systems score.

A stale tab id answers with the ids that *are* open, rather than a bare
failure, since a caller holding a dead handle needs to know what to hold
instead.

Left standing: nothing runs a script *under* a handoff -- if a challenge
appears at step four, the reply says so and the caller starts a new call once
a human has cleared it. Whether a script should be able to wait for that
in-line is unexamined.
