---
id: 036
title: One skill for this server, and docstrings cut to the contract
labels: [wayfinder:task]
status: closed
assignee: glyh
blocked_by: []
---

## Question

The build half of [Six skills restate the server
instructions](032-skills-restate-the-instructions.md), which decided the
shape. Nothing here is open; what is left is doing it and finding out what
breaks.

**Write `skills/using-agent-browser/SKILL.md` in this repo**, symlinked into
`~/.agents/skills/using-agent-browser` the way seven skills on this machine already
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
- **The wall phrases**, as examples rather than a table: a short page saying
  "verify you are human", "请完成验证", or a login prompt where content was
  expected. [038](038-a-fetched-that-says-this-reads-like-a-wall.md) refused
  to put these in the tool, which makes the skill the only place they can
  live, and makes this the part of the skill that carries the most weight.

The standing rule behind all of this, from
[038](038-a-fetched-that-says-this-reads-like-a-wall.md): the tool reports
what it measured, the skill holds what to look for.

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
2. **Drift between the skill and the code: accepted, not solved.** Nothing
   fails if the skill goes stale, and no test was written. The realistic
   candidates were a test asserting phrases appear in `SKILL.md` -- brittle,
   and green while the sentence is wrong -- or a checklist line. This was
   settled as a general problem rather than this repo's: a skill is
   documentation of an interface, and documentation drifting from the thing it
   documents is the same shape as a library's docs falling behind its API.
   Nobody has solved that; one copy in the same repo as the code is the honest
   floor. The mitigation is proximity, which is why the skill ships from here
   and not from the vault.

3. **A wikilink is not a load, and that is a taken risk.** Point 6's premise
   is that a skill is the one address a skill can name -- but naming it does
   not invoke it. If an agent reads `[[using-agent-browser]]` in a vault skill and
   does not follow it, it gets *less* than before the cut, since the docstring
   prose it would have fallen back on is gone. Three options were weighed and
   the first was chosen: trust that skills citing skills works. Refused were a
   one-line floor left in each docstring (the duplication returning in
   miniature) and probing it first the way point 5 was probed. The probe was
   recommended and declined, so this is a decision made on judgement rather
   than measurement -- recorded here so that a later session finding walls
   being missed in the vault knows where to look first, and knows the cheap
   experiment was never run.
4. **The README.** It has its own prose about modes and about what gets
   recognised, and [019](019-the-tool-does-not-learn.md) already made it point
   at `status` rather than keep a copy of the signature list. Check it does
   not become the next place the paragraph lives.
5. **CLI parity.** The docstrings serve the MCP door; `ab/cli.py` is the
   other one. Nothing here should change what a human reading `--help` gets,
   and if it does, that is [One description, two
   doors](026-one-description-two-doors.md)'s problem arriving early.

## Answer

**Built.** `skills/using-agent-browser/SKILL.md`, 120 lines, symlinked to
`~/.agents/skills/using-agent-browser`, and it registered on this session --
its description shows up in the skill listing, so the address 032 said did not
exist now does.

Named `using-agent-browser` rather than `agent-browser` so it cannot be
mistaken for the MCP server itself in a listing where both appear.

**What the docstrings lost.** `fetch` went from four paragraphs to two lines;
`show_browser` from three to three sentences. The `instructions` block went
from 1,400 characters to 476 -- what the tool is for, then a pointer at the
skill. Field descriptions are untouched to the byte, `script`'s docstring
untouched (it was already contract-only), and the CLI never changed, so
`--help` reads exactly as it did.

Six sections in the skill: the measure/judge division, walls and the ones the
tool cannot see, a fetch is one screen, pictures are not in the markdown,
prefer reading to driving, and the tool remembers nothing.

**Item 1, read cold: one line was nearly lost.** `show_browser`'s "also the
way to ask for a human deliberately" was the piece most at risk, exactly as
the ticket predicted, so it is the one sentence of operating knowledge kept in
a docstring -- not as insurance, but because it is a fact about *when this
tool applies*, which is contract. The rest went.

**Item 4, the README, needed the cut too.** It was already a second copy: a
ten-line bullet restating the whole soft-wall procedure to a human reader.
Trimmed to what is genuinely README material -- that `show_browser` exists at
all because over MCP the caller is not a human, unlike the CLI -- and it now
points at the skill for the procedure, the way
[019](019-the-tool-does-not-learn.md) made it point at `status` instead of
keeping its own copy of the signature list. `skills/` is in the Layout table.
This is the third thing found carrying the paragraph, after the docstrings and
the vault's `CLAUDE.md`; whatever else this ticket was, the count was never
six.

**Verified.** `mypy --strict` clean over 21 files, `nix flake check` green.
The skill loaded and listed in a live session. Nothing was tested about the
skill's *content*, per item 2 -- there is nothing to test it against.
