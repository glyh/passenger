---
id: 046
title: Retire fetch: a tab and a script, and extraction becomes the agent's
labels: [wayfinder:grilling]
status: open
assignee:
blocked_by: []
---

## Question


`fetch` goes. What remains is a way to put a page in a tab and a way to run code
against it: `open_tab` navigates and hands back a handle, parsing nothing;
`script` is where reading happens, written by the caller. `dom` mode stops being
a mode and becomes a **recipe** the agent copies out of a skill.

## Why this is not a new idea, but the conclusion of an old one

[How thin can this layer get](020-how-thin-can-this-layer-get.md) asks the
question; [Reaching content that sits behind an
interaction](004-driving-the-page.md) answered it for *verbs* -- one door with
`page` bound, rather than a tool per Playwright call -- and explicitly left the
same question owed to every tool that predates it. `fetch` predates it. This is
that debt.

**The evidence is a decade of deletions in one map.** Six mechanisms have now
been removed or refused for ruling on what a page means: the yield floor
([011](011-listing-clears-the-yield-floor.md)), `min_words`
([005](005-mode-decides-blocked.md)), the learned signature registry
([019](019-the-tool-does-not-learn.md)), `auto`
([021](021-remove-auto-mode.md)), the wall hint
([038](038-a-fetched-that-says-this-reads-like-a-wall.md)), and
[016](016-the-result-says-what-it-missed.md), which built nothing because its
own finding killed it.

**And what stayed is still failing.** `_ROOTS` is six selectors and a 40-char
guard that returned a promo card as the document
([028](028-the-root-heuristic-picks-a-decoy.md)). `article` deletes chinadaily's
pagination links, loses chinanews's labels, and swallows gmw's hidden WeChat
overlay ([025](025-whether-dom-alone-is-enough.md)). `dom` returns 128,718
characters around a 9,569-character post. 12306 returns **zero** characters from
a page holding 2,647 ([039](039-extractor-returns-nothing-on-12306.md)) -- and
the two agents who hit it worked it out unaided and reached for `inner_text`,
which is this ticket's thesis demonstrated by accident.

The tool has been losing this argument its whole life, one ticket at a time.
Extraction *is* the judgement, and the standing division says judgement is the
caller's.

## What it collapses

Recorded because it is most of the value, and because these tickets should not
be worked on before this is decided:

- [Build drop_run](045-build-drop-run.md) -- becomes a recipe, not a feature.
- [Whether article's last job can be done
  structurally](044-articles-last-job-structurally.md) -- closed with a design
  that this deletes. The *measurement* in its asset survives and is exactly the
  kind of thing a recipe would do.
- [One extractor instead of two](029-one-extractor-instead-of-two.md) and
  [Whether dom alone is enough](025-whether-dom-alone-is-enough.md) -- lose
  their subject. Neither extractor exists to compare.
- [One description, two doors](026-one-description-two-doors.md) -- shrinks to
  two verbs, and most of the drift it catalogues is `fetch`'s parameters.
- [Whether this moves to C#](023-rewriting-into-csharp.md) -- **loses its
  expensive half.** The ~5,500 lines of trafilatura plus justext plus an
  XPath-capable DOM library stop needing a port at all, which is most of what
  made the port expensive.

## What must survive, or this is a regression

1. **The measurements are not extraction.** `blocked` is a match against a fixed
   table of vendors' own markup -- 038 kept `BUILTIN` precisely because a vendor
   either serves that markup or does not, and that is a measurement. So are
   `char_count` and `largest_image` ([017](017-a-payload-that-is-not-text.md)).
   If they die with `fetch`, the caller loses wall detection that took three
   tickets to get right and gains nothing. They belong on `open_tab`, or on
   something that measures without parsing.
2. **The recipes have to live somewhere and stay right.** The
   `using-passenger` skill is the obvious home
   ([036](036-one-skill-for-this-server.md)), but
   [032](032-skills-restate-the-instructions.md) recorded that an agent treats
   the document in front of it as the whole procedure. A recipe that is subtly
   wrong is worse than a tool that is subtly wrong, because nothing versions it.
3. **The walker's semantics are not trivially re-derivable.** `walker.js` is 165
   lines that took 007, 009, 015, 028, 034 and 035 to get right -- resolved
   hrefs, `checkVisibility({visibilityProperty: true})` but *not* `opacity`,
   deferred list markers, fenced `PRE`. An agent writing `inner_text('body')`
   gets none of it. If the recipe is just `inner_text`, this trades a mediocre
   extractor for a much worse one.

## To decide

1. **Whether `open_tab` is redundant.** `script` can already `page.goto(...)`
   and take `read_page=False`. The maximal reading of 004 is *one* door, not
   two. The case for `open_tab` is that "just open this page" should not require
   writing Python, and a handoff needs a tab before there is anything to run.
   Decide it rather than inherit it.
2. **What `script` returns when the caller does not parse.** Today `read(page)`
   is in scope and is the thing being retired. Does it stay as a recipe compiled
   in, does it become nothing, or does `script` keep a raw `inner_text` as the
   floor?
3. **Where the measurements go**, per the constraint above.
4. **Whether the CLI keeps `fetch`.** Its caller is a human at a terminal, and
   making a person write Python to read a page is a worse tool.
   [018](018-asking-for-a-human.md) already established the two doors
   legitimately differ where the caller differs. This may be an asymmetry to
   embrace rather than 026 drift -- but it should be chosen.
5. **What the cost is, per page, for an agent.** `fetch` is one call. A tab plus
   a script is two, plus the tokens of the recipe itself. For twenty pages that
   is forty round trips. Whether a recipe can be one `script` call that navigates
   *and* reads is the thing that decides if this is cheaper or dearer in the
   currency that actually binds an agent.
6. **What happens to `walker.js`.** Deleted, or kept as the canonical recipe
   shipped in the skill? If kept, it is no longer code this project runs but
   text this project publishes, which is a different maintenance contract and a
   different failure mode.
