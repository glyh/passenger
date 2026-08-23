---
id: 019
title: The tool does not learn; the agent remembers
labels: [wayfinder:task]
status: open
assignee:
blocked_by: [018]
---

## Question

[The extract mode decides whether a page counts as
blocked](005-mode-decides-blocked.md) deleted the thing that *wrote* to
the signature registry and deliberately kept the half that curates it --
`pending_review`, `approve`, `forget`, the on-disk `learned` list. That
was the conservative call at the time. The stance now is that the whole
mechanism should go, and for a reason better than "nothing fills it".

**A tool that learns is a second memory, owned by the wrong party.** The
caller here is an agent with its own persistent memory, one that already
holds project-scoped facts across sessions and that a human can read and
correct. "This site puts its comments behind a login", "that domain sits
behind DataDome" is exactly that kind of fact. Putting it in
`signatures.json` instead files it somewhere the agent cannot see, cannot
explain, and cannot revise -- it can only be surprised by it. The eight
proposals 005 found on disk were invisible to every session that would
have been affected by them.

The failure mode is not hypothetical. A learned rule is a judgement made
once, from one page, that then acts silently and forever. Agent memory
has the opposite shape: written deliberately, attributed, re-read in
context, and cheap to delete when it turns out to be wrong.

Note the builtins are a different thing and stay. Cloudflare, Turnstile,
hCaptcha, Arkose, DataDome, PerimeterX, login walls -- that is a fixed
table of how the world's challenge vendors identify themselves, shipped
with the tool and true regardless of who is calling. It is knowledge
about *challenge vendors*, not about the caller's sites.

Blocked on [Asking for a human, rather than being guessed
at](018-asking-for-a-human.md), and this is the real dependency rather
than a formality: today a site-specific signature is the only way to make
a handoff fire on a site the builtins do not recognise. Remove learning
before a caller can ask for a human deliberately and that becomes
unreachable. Afterwards it is the agent's job -- read the page, recognise
the wall, remember it, ask for the human next time.

To decide:

1. How much comes out. `Registry.learned`, `pending_review`, `approve`,
   `forget`, `load`/`save`, the `signatures.json` file itself, and the
   `Signature` fields that only served proposals (`seen_at`, `evidence`).
   `active()` collapses to `BUILTIN`, and the registry stops touching
   disk at all.
2. What `signatures` the command becomes. Listing the builtins is still
   worth having -- it is how a caller learns what the tool can recognise
   without reading the source.
3. Whether anything should be said at the boundary. If the tool no longer
   remembers, the thing that does needs to be told: a line in the MCP
   tool description, or in the `blocked` hint, that recognising a wall
   this tool does not know is the caller's to record.
4. What to do with an existing `signatures.json` on disk. Ignoring it
   silently is one answer; refusing to start is not.
