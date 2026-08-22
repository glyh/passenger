---
id: 013
title: The passthrough tool that runs a script against a page
labels: [wayfinder:task]
status: open
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
