---
id: 036
title: One skill for this server, and docstrings cut to the contract
labels: [wayfinder:task]
status: open
assignee: glyh
blocked_by: []
---

## Question

The build half of [Six skills restate the server
instructions](032-skills-restate-the-instructions.md), which decided the
shape. Nothing here is open; what is left is doing it and finding out what
breaks.

**Write `skills/agent-browser/SKILL.md` in this repo**, symlinked into
`~/.agents/skills/agent-browser` the way seven skills on this machine already
are. It holds the operating knowledge that is true before any particular call:

- `blocked` fires on a fixed table of vendor signatures and nothing else. A
  soft wall arrives as ordinary `fetched` content. Recognise it yourself,
  `show_browser(tab, wait_seconds, notify_human)`, then re-read the tab with
  `script` and judge -- `show_browser` never inspects the page.
- `fetch` is goto, settle, read. Anything the page defers until a reader
  scrolls or clicks is not in the result and nothing says so. Look in the
  markdown for the page's own account of what it withheld.
- Prefer reading over driving. Synthetic clicks have no cursor path and no
  keystroke timing; driving spends the reputation of a session whose value is
  that it has never done anything unusual.
- `close_tabs` after a batch.
- The tool learns nothing between calls. What you find out about a site is
  yours to remember -- see [The tool does not
  learn](019-the-tool-does-not-learn.md).
- `largest_image` read against `char_count`, and how to reach the picture --
  the calibration from [A payload that is not text](017-a-payload-that-is-not-text.md).

**Then cut the docstrings to the call contract.** `fetch` loses all four
paragraphs and becomes two lines; `show_browser` loses its three. Field
descriptions stay untouched and in full -- 032 is explicit that `mode`'s two
lines are [021](021-remove-auto-mode.md)'s replacement for deleted code, not
commentary, and that `script`'s "never a locator" prevents a call that would
otherwise fail. The server `instructions` block shrinks to what the tool is
for plus a pointer at the skill.

To watch for while doing it:

1. **What the cut actually leaves.** Read `fetch`'s remaining two lines cold,
   as an agent with no skill loaded, and check that nothing load-bearing left
   with the prose. The one line most likely to be missed is `show_browser`
   being the way to ask for a human deliberately, not just the answer to a
   `blocked` reply.
2. **Whether anything holds the two together.** The skill and the code are now
   in one repo, which is the whole point -- but nothing fails if the skill
   goes stale. 032's answer names no test. Whether one is possible, or whether
   proximity plus a single copy is the honest floor, is worth ten minutes
   before concluding it is not.
3. **The README.** It has its own prose about modes and about what gets
   recognised, and [019](019-the-tool-does-not-learn.md) already made it point
   at `status` rather than keep a copy of the signature list. Check it does
   not become the next place the paragraph lives.
4. **CLI parity.** The docstrings serve the MCP door; `ab/cli.py` is the
   other one. Nothing here should change what a human reading `--help` gets,
   and if it does, that is [One description, two
   doors](026-one-description-two-doors.md)'s problem arriving early.
