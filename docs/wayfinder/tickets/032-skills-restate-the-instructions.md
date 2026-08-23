---
id: 032
title: Six skills restate the server instructions
labels: [wayfinder:grilling]
status: closed
assignee: glyh
blocked_by: []
---

## Question

A session spent today updating the six scraping skills in the Notes vault
(`xiaohongshu`, `reddit`, `web-search`, `china-fangjia`, `railway-12306`,
`settlement-city-research`) put the same paragraph into all six:

> `blocked` only fires on known vendor signatures. A soft wall comes back
> as ordinary `fetched` content with a small `word_count`. Do not wait for
> the verdict -- recognise the wall yourself and call `show_browser(tab,
> wait_seconds, notify_human)`, then re-read the tab and judge, because
> `show_browser` never inspects the page.

That is the third paragraph of this server's own instructions, and the
back half of `show_browser`'s docstring. It was written out six times
anyway, by an agent that had both in context at the time.

It is not the only one. Also copied into skill after skill: run
`close_tabs` after a batch; prefer reading over driving because synthetic
clicks spend a session's reputation; `fetch` is goto-settle-read, so look
in the markdown for the page's own account of what it withheld. All four
are things this side already says. One skill goes further and carries
`min_words 已经没有了（agent-browser ticket 005）` -- a note in a vault
pinned to this repo's ticket numbering, which goes stale the day 021 or
029 lands.

**The split that matters.** Not everything in those skills is duplication.
That `article` mode on a Xiaohongshu search page returns 220 words of ICP
footer and zero cards; that aqicn answers a city with no station by
serving the global page under a different `<title>`; that 12306 quietly
widens a station pair into a city pair -- none of that is knowledge this
tool has or should have. [The tool does not learn; the agent
remembers](019-the-tool-does-not-learn.md) is exactly right about it, and
a skill is the good end of that arrangement: a durable, human-editable,
site-scoped memory. This ticket is the mirror question. Site knowledge
belongs to the caller. *Tool* knowledge belongs here -- so why is the
caller hand-copying it, and where should it live so that it stops?

**Why it happened**, as best the session can reconstruct:

1. **The instructions arrive before there is a task.** They are injected
   once, at session start, alongside every other server's. A skill arrives
   at the moment of the work and is the proximate authority; an agent
   following one reads it as the complete procedure for the job, and
   completes it.
2. **A skill author cannot assume the instructions are present.** The same
   skill may be run by a subagent, from a fresh process, or on a machine
   where the MCP is connected differently. Restating is the defensive
   choice, and it is not obviously the wrong one.
3. **There is nothing to point at.** A skill can link to another skill by
   wikilink. It has no way to say "and the tool's own handling of walls is
   over there" -- no stable anchor, no address. Copying is the only
   transclusion available.

To decide:

1. **Whether restating is actually a problem.** The cost is not bytes, it
   is drift: six copies of a paragraph about `blocked` all go wrong
   together on the day this side changes what `blocked` means, and nothing
   fails when they do. Weigh that against a skill that silently omits the
   handoff because it trusted instructions that were not there. This is
   the same shape as [One description, two doors](026-one-description-two-doors.md)
   -- hand-mirrored prose that no test can hold together -- one layer out.
2. **A resource with an address.** MCP servers can expose resources, and a
   caller here can already list and read them. If the operating knowledge
   were readable at a stable URI, a skill could cite it in one line instead
   of paraphrasing it. Whether an agent mid-task actually spends a call on
   it is the open half.
3. **Moving it into the per-call descriptions.** Knowledge in a tool's
   docstring arrives at the moment of use rather than at session start,
   which is when it is needed. `show_browser` already carries most of this
   and it still got copied -- so the question is whether the *fetch* and
   *script* docstrings, the ones an agent is actually reading when it hits
   a wall, say enough. That is the cheapest thing on this list to try.
4. **Saying it in the result, at the moment it is true.** The strongest
   version. [The result says what it did not
   reach](016-the-result-says-what-it-missed.md) already built this
   shape for withheld content: a pure function over the extraction, a field
   on `Fetched`, and both doors get it because both build through
   `service._fetched`. A thin page whose text says "verify you are human"
   and did not match a builtin is the same kind of observation, and a
   `Fetched` that carried "this reads like a wall; `show_browser` is how
   you ask for a human" could not be forgotten, could not be copied wrong,
   and would need no paragraph in any skill. The trap is 011 and 008: this
   must key on what the page *says*, never on how short it is. A word-count
   floor was deleted twice for good reasons and must not return wearing a
   hint's clothing.
5. **Whether the subagent/CLI gap is real.** Reason 2 above is the whole
   justification for defensive restating, and nobody has checked it. If
   server instructions do reach every context that can call these tools,
   the honest fix is a line in the vault's `CLAUDE.md` saying skills do not
   restate tool behaviour, and no code changes here at all.

6. **A skill for this server, that the others cite.** The owner's idea, and
   it answers reason 3 directly: the reason six skills copied the paragraph
   is that there was nothing to point at, and a skill *is* the one address a
   skill can already name. One `agent-browser` skill holds the operating
   knowledge -- what `blocked` does and does not fire on, why reading beats
   driving, `close_tabs` after a batch, `fetch` is goto-settle-read -- and
   the six site skills carry only what is theirs, with a wikilink where the
   paragraph used to be. Unlike server instructions it arrives at the moment
   of work rather than at session start, which is reason 1's whole
   complaint.
   Open, and worth deciding before writing it: **where it lives.** In the
   Notes vault it is a seventh copy of tool knowledge outside this repo,
   drifting the same way, only now once instead of six times -- which is a
   real improvement in blast radius and no improvement in kind. Shipped
   *from* this repo, next to the code it describes, it is the same artifact
   with a chance of staying true, and the vault skills link to it by name.
   That makes it the skill-shaped answer to point 2's resource, with the
   addressing problem already solved. It does not subsume 4: a skill still
   has to be loaded, and a `Fetched` that says "this reads like a wall"
   arrives whether anything was loaded or not.

Point 4 subsumes the most valuable case and 3 is nearly free; they are not
alternatives, and 6 is the cheapest thing that stops the copying today. What
none of them settles is the general problem -- an agent mid-task treats the
document in front of it as the whole procedure -- and that may not be this
repo's to solve.

## Answer

**Point 6, and the docstrings go with it.** One `using-agent-browser` skill,
shipped from this repo, holds the operating knowledge; the six vault skills
carry only what is theirs and link to it by name; the tool docstrings are cut
to the call contract and the server `instructions` block shrinks to a pointer.
Three copies of the same paragraph collapse to one, in git, next to the code
it describes.

### Reason 2 is false, and the check was cheap

The ticket's point 5 -- nobody has checked whether server instructions reach
every context that can call these tools -- was the whole justification for
defensive restating. Two probes, a subagent and a fresh headless `claude -p`
in the Notes vault:

- The subagent began with **neither**. The seven `mcp__agent-browser__*` tools
  arrived as bare names in a deferred list, no schemas, and no
  `# MCP Server Instructions` section existed. One `ToolSearch` call and both
  appeared together -- the instructions block *and* the full four paragraphs
  of `fetch`'s docstring, `largest_image` calibration intact.
- The headless run's first turn landed before the MCP server finished
  connecting: no tools, no instructions, nothing. A second run that loaded the
  tools had both.

So **there is no context where a docstring arrives but the instructions do
not.** They are one channel, gated by one event. Nobody needed to copy
anything, and a skill author's fear of an absent instructions block was a fear
of a state in which the tool is not callable either.

Two things this overturns:

1. **Reason 1 is obsolete in this harness.** The ticket's complaint is that
   instructions are injected at session start, before there is a task, which
   was the whole argument for preferring a docstring's moment-of-use arrival.
   Deferred tool loading already fixed that: they arrive when the tools do.
2. **A gap the ticket did not see.** Until something triggers the load, an
   agent has *neither* -- which is precisely planning time, when it is reading
   a skill and deciding what to do. The skill is the only one of the three
   channels that reaches there. That is a better argument for point 6 than the
   ticket made for itself.

Caveat, recorded honestly: both probes are models self-reporting on their own
context. They corroborate, and the headless run reproduces from a clean
process, but this is testimony rather than a wire capture.

### Where it lives

`skills/using-agent-browser/` in this repo, symlinked into `~/.agents/skills/` --
the arrangement seven skills on this machine already use
(`efficient-text-process`, `ocaml-alcotest`, `safe-git-rebase` and the rest
are symlinks into `~/pullground/my-skills`). The ticket's worry about a
seventh copy of tool knowledge drifting outside the repo does not arise: the
skill is in git beside the code, and the vault cites it by name.

### The carve: schema stays, prose goes

Two different things live in `mcp_server.py`, and only one of them is
duplicated knowledge.

**Field descriptions stay, in full.** `mode`, `source`, `tab`,
`wait_seconds`, `notify_human`. These are the call contract; they have to
arrive with the signature, and a skill cannot hold them. `mode`'s two lines in
particular are not commentary -- [Remove auto mode](021-remove-auto-mode.md)
chose them *as the replacement for deleted code*, saying what `choose` was
trying to compute and naming the failure ("`article` returns the footer of a
listing"). Stripping them would leave a required argument with nothing to
answer it by, and would quietly restore the xiaohongshu failure this very
ticket cites as evidence. `script`'s "it must be JSON, so return `page.url` or
`read(page)`, never a locator" is the same kind of thing: it prevents a call
that would otherwise fail.

**Docstring prose goes.** `fetch`'s four paragraphs and `show_browser`'s
three: goto-settle-read, look in the markdown for the page's own account of
what it withheld, the `largest_image` against `char_count` reading, "it learns
nothing between calls", "recognise the wall yourself". Every one is a standing
fact about the tool, true before any particular call exists, and every one is
on this ticket's list of what got hand-copied. `fetch` drops to two lines.

The aggressive version is the *better* version here, and that is worth being
explicit about: a shipped skill plus intact docstrings would be two copies
inside one repo -- an improvement in blast radius over six, and no improvement
in kind, which is the same objection the ticket raises against a vault copy.
Moving the prose rather than mirroring it is what makes this a deduplication
instead of a fourth copy.

### A fourth copy, found while checking

The Notes vault's own `CLAUDE.md` carries a `### Web fetching -- fall back to
agent-browser` section. So the count was never six skills; it was six skills,
a project instruction file, the server instructions and the docstrings, all
saying overlapping versions of the same thing. The vault-side cleanup is
[The vault stops restating this side](037-vault-skills-cite-the-skill.md).

### What this does not settle

Point 4 -- a `Fetched` that says "this reads like a wall" -- is untouched, as
the ticket said it would be: a skill has to be loaded and a field does not.
But it is in more trouble than the ticket knew. Keying on what the page
*says* is a text-pattern table, and that is the shape
[The tool does not learn](019-the-tool-does-not-learn.md) deleted and
[The result says what it did not reach](016-the-result-says-what-it-missed.md)
refused on the grounds that a regex table is a worse recognizer than the agent
it would serve. It is opened as [A Fetched that says this reads like a
wall](038-a-fetched-that-says-this-reads-like-a-wall.md) rather than decided
here, because refusing it on precedent alone would be deciding a live question
in a footnote.

And the general problem stands, unowned: an agent mid-task treats the document
in front of it as the whole procedure. That is why the six copies were written
by an agent that had both originals in context. Nothing here fixes it; the
skill only makes the document in front of it the right one.

### The work

- [One skill for this server, and docstrings cut to the
  contract](036-one-skill-for-this-server.md)
- [The vault stops restating this side](037-vault-skills-cite-the-skill.md)
- [A Fetched that says this reads like a
  wall](038-a-fetched-that-says-this-reads-like-a-wall.md)
