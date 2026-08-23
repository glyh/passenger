---
id: 037
title: The vault stops restating this side
labels: [wayfinder:task]
status: open
assignee: glyh
blocked_by: [036]
---

## Question

The other half of [Six skills restate the server
instructions](032-skills-restate-the-instructions.md), outside this repo.
Blocked by [036](036-one-skill-for-this-server.md), because there is nothing
to cite until the skill exists.

In `~/Documents/Notes`, six skills -- `xiaohongshu`, `reddit`, `web-search`,
`china-fangjia`, `railway-12306`, `settlement-city-research` -- each carry a
paragraph of this server's operating knowledge. Replace each with a wikilink
to `agent-browser` and keep only what is theirs: that `article` on a
Xiaohongshu search page returns 220 words of ICP footer, that aqicn serves the
global page under a different `<title>` for a city with no station, that 12306
quietly widens a station pair into a city pair. That knowledge is the good end
of [The tool does not learn](019-the-tool-does-not-learn.md) and none of it
moves.

Two specifics found while resolving 032:

- **A seventh copy.** The vault's own `CLAUDE.md` has a `### Web fetching --
  fall back to agent-browser` section. It is project-level rather than
  skill-level, so it may be load-bearing in a way the six are not -- it fires
  without any skill being invoked, which 032 found is the one context where
  neither the instructions nor the docstrings have arrived yet. Decide whether
  it shrinks to a pointer or stays as the vault's own bootstrap.
- **A stale cross-repo reference.** One skill carries `min_words 已经没有了
  (agent-browser ticket 005)`. A vault note pinned to this repo's ticket
  numbering is a dangling pointer by construction -- and this one is already
  wrong twice over, since 021 and 022 both landed. It goes; the skill should
  say what is true, not which ticket made it true.

Then a line in the vault's `CLAUDE.md` saying skills do not restate tool
behaviour, which is what 032's point 5 concluded was the honest fix once the
subagent gap turned out not to exist.
