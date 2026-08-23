---
id: 037
title: The vault stops restating this side
labels: [wayfinder:task]
status: closed
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

## Answer

**Done, in `~/Documents/Notes`.** Six skills cut, the vault's `CLAUDE.md` kept as
bootstrap and shrunk, and the rule written down. 79 lines removed, 49 added.

**What each skill kept.** Every copy of the `blocked`/`show_browser`/`close_tabs`
paragraph went; what stayed is the site fact that made the skill worth writing:

- `xiaohongshu` — that Xiaohongshu's own wall arrives as 「登录后查看搜索结果」 rather
  than a verdict, while `/user/profile/<id>` really does return
  `blocked, name='login-wall'`; the page's own `共 N 条评论` / `展开 N 条回复` counters
  to reconcile against; `auto` on the search page and its 0.39-vs-0.35 ratio.
- `china-fangjia` — that 58.com's captcha is *self-made*, so it cannot be a vendor
  signature and shows up only as a `title` that is no longer the target city, which the
  existing 铁律 `title` check already catches. The duplicate copy of that fact further
  down the file now points at the one above it.
- `settlement-city-research` — aqicn's global page under a different `<title>`; the
  serial-not-concurrent pacing, which is about the sites, not the tool.
- `railway-12306`, `reddit` — both only ever said "if you hit a wall, here is the
  procedure"; both are now one line naming the skill.
- `web-search` — 铁律 2 shrank to the site-shaped half: *a search page that looks like
  "no results" is usually a wall*. DuckDuckGo's duck captcha and the "resend once"
  remedy stay; they are DuckDuckGo's, not the tool's.

**The seventh copy stays, as bootstrap.** The ticket's first specific was right that
`CLAUDE.md` is different in kind: it is the only thing that fires at planning time,
before any skill or tool schema has loaded. So it keeps the "retry through
agent-browser, don't call a site unreachable until it has failed too" instruction —
and loses the one line of tool behaviour it carried, which was
`type='blocked'` → a human must solve it. That line was not merely duplicated, it was
*wrong in the direction that matters*: it taught waiting for a verdict that never
arrives for a soft wall. In its place, a bullet naming `using-agent-browser` and saying
to load it before the first call.

**The stale cross-repo reference was already half gone.** `agent-browser ticket 005`
no longer appeared anywhere in the vault; only the `min_words` sentence remained. It
went with the rest of 铁律 2 — a parameter that does not exist is answered by the
schema rejecting it, not by a skill remembering its funeral.

**The rule, in `CLAUDE.md`:** vault skills carry only what is true about *their site*;
anything true about a *tool* is cited by name, never copied — with the drift argument
stated, since a rule whose reason is missing is the next thing to be edited away. Same
line forbids cross-repo ticket pointers.

**Backtick citation, not a wikilink.** The ticket asked for a wikilink to
`agent-browser`. It does not get one: `using-agent-browser` ships from this repo and is
reachable through `~/.agents/skills/`, so `[[using-agent-browser]]` resolves to nothing
in the vault, and the vault's own `CLAUDE.md` (§3b, §3c) forbids exactly that — an
unresolvable link is the dangling cross-repo pointer this ticket's second specific was
written to delete. The skills name it in backticks the way the server's own
`instructions` block does, which is the address an agent can actually act on: it is a
`Skill` invocation, not a file path.

**Not verified:** whether an agent reading `using-agent-browser` in a vault skill
actually loads it. That is [036](036-one-skill-for-this-server.md)'s item 3, taken on
judgement there and inherited here unchanged; the vault is now the place where a miss
would show up first.

### Follow-on, same session: the rule got stricter than the ticket asked

The owner's follow-up while this was being checked: *don't describe how to scrape
anywhere outside `Notes/skills`*. So the `CLAUDE.md` line is not only "skills do not
restate tool behaviour" but two halves — outside `skills/` say **nothing** about how,
inside a skill say only what is that **site's**. What moved as a result:

- `News/CLAUDE.md` carried the Reddit channel-A URL, the `.json` query string, "one
  script call for all four subs", and the channel-B fallback. All of it is in the
  `reddit` skill; the briefing file keeps only the editorial half — which field may be
  quoted as popularity, and that the two channels' numbers never share a card.
- `memory/ratchakitcha-gazette-access.md` was a full scraping how-to for the Thai Royal
  Gazette living in a memory note. It became `skills/ratchakitcha/SKILL.md`; the memory
  is now three lines saying the source exists and what question it answers.
- That note also carried **"agent-browser 只能取页、不能点击"** — a false claim about
  this tool, propagated into two briefings. `script` is Playwright. The skill now says
  what was actually verified (the search box's URL params don't reach the query) and
  records that driving it was never tried. This is the failure mode 032 predicted,
  found in the wild: not six copies drifting together, but one copy drifting alone
  where nobody would look.

A vault-wide audit for leftovers: phrase-level greps for every fact the skill owns, a
14-character-window overlap scan of the skill against every `.md` in the vault, and a
sweep for tool names outside `skills/`. What remains outside `skills/` is the bootstrap
line naming the MCP server, and two dated briefing entries, which are logs of what was
believed that day and were left alone.
