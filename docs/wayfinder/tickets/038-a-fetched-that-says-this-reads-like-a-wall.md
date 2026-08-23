---
id: 038
title: A Fetched that says this reads like a wall
labels: [wayfinder:grilling]
status: open
assignee: glyh
blocked_by: []
---

## Question

Point 4 of [Six skills restate the server
instructions](032-skills-restate-the-instructions.md), which 032 deliberately
did not decide. A skill has to be loaded; a field on `Fetched` does not, so
this is the one channel that arrives unconditionally -- and 032 found that
until something triggers the tool load, an agent has neither the server
instructions nor the docstrings. That is the strongest case anyone has made
for putting the knowledge in the result.

The proposal: a thin page whose text plainly says "verify you are human" and
did not match a builtin signature is an observation this side can make, and a
`Fetched` carrying "this reads like a wall; `show_browser` is how you ask for
a human" could not be forgotten, could not be copied wrong, and would need no
paragraph in any skill. The shape already exists -- a pure function over the
extraction, a field on `Fetched`, both doors getting it through
`service._fetched`, exactly as [017](017-a-payload-that-is-not-text.md) built
`largest_image`.

**The case against, which is heavier than 032 realised.** Keying on what the
page *says* is a text-pattern table.

- [The tool does not learn](019-the-tool-does-not-learn.md) deleted precisely
  that, and kept `BUILTIN` only because a vendor signature is "a fixed table
  about how vendors identify themselves, true regardless of who is calling."
  A phrase like "verify you are human" is not that: it is per-language,
  per-site, and open-ended -- the learned list wearing a builtin's clothes.
- [The result says what it did not reach](016-the-result-says-what-it-missed.md)
  refused a near-identical mechanism and gave the reason: the markers are
  already in the markdown the caller holds, and a per-language regex table is
  a worse recognizer than the agent it would serve. Every word of that applies
  here. It also left the one condition under which it should be revisited --
  if output is ever capped, so markers can fall outside what the caller
  receives -- and that condition has not fired.
- [005](005-mode-decides-blocked.md) and [021](021-remove-auto-mode.md)
  removed ruling-on-your-own-number everywhere else, and 017 shipped its
  geometry with no bucket word and no floor for the same reason.

So the real question is whether this is meaningfully different from what 016
already refused, or whether it is 016 with a new name. If there is a
difference it is this: 016 was about content the page withheld and said so,
where the caller genuinely holds the evidence. A wall is about the page not
being the page at all, and the agent may not look twice at 300 characters that
parse as prose.

The trap, if it is built: it must key on what the page *says*, never on how
short it is. A word-count floor was deleted in 005 and again in 011 for good
reasons and must not return wearing a hint's clothing.

Worth deciding before 036's cut settles, since a `Fetched` that says this
would remove the need for the skill to say it at all.
