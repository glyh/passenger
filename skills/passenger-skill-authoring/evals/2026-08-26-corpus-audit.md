# Corpus audit: 18 produced skills

**Conclusion: the rules in this document held; the gaps were things it did not
say.** Eight changes went in, all of them ratifying something the corpus had
already worked out unprompted or fixing a drift it had no rule against.

## Conditions

- Read every `SKILL.md` and `references/` under `~/Documents/Notes/skills`:
  18 `passenger-*` skills plus one pre-`passenger-` skill (`zhihu/`).
- Static read only. No skill was re-run against its site, so nothing here
  measures whether a skill still works — only what it says.
- Authoring doc at commit `42b6cdc`.

## Numbers

**Adherence to rules the doc already had — all held:**

| Check | Result |
| --- | --- |
| Changelog voice ("previously", "originally", "now overturned", and the Chinese equivalents) | 0 violations |
| Dates outside baseline provenance | 0 violations |
| Mechanism in `description` | 0 violations |
| `verified`-style hedging on unrun recipes | present where expected (aqicn, zhihu, flights) |

**Self-check coverage — rules (`###`) vs self-check markers:**

| Skill | Rules | With self-check |
| --- | --- | --- |
| weixin | 13 | 13 |
| tieba | 12 | 12 |
| zhihu | 8 | 9 |
| weather-cma | 12 | 8 |
| thai-gazette | 8 | 6 |
| dianping | 8 | 6 |
| reddit | 11 | 6 |
| facebook | 7 | 5 |
| flights | 5 | 4 |
| google-maps | 8 | **3** |
| xiaohongshu | 6 | **3** |
| anjuke | 5 | **3** |

Roughly 40% missing across the corpus. The three at 100% are the three whose
author had a repeatable marker string; the low ones vary the phrasing or omit it.

**Structure:**

- No baseline section: facebook, reddit, weixin (3/18) — all large, and all
  three had distributed the numbers into their rules instead.
- No reporting-requirements section (`口径`): thai-gazette.
- No capability table: reddit, 12306.
- Sizes: 91–390 lines for `SKILL.md`. Largest with no `references/` at all:
  zhihu, 390 lines, and the most usable in the set.

**Two layouts, converged on unprompted:**

- Lookup — hard rules / capability table / how to fetch / baselines / quota and
  driving / reporting requirements. Five of anjuke, beike, fangtianxia, bing,
  google-search, aqicn are heading-for-heading identical. None grew a
  methodology section.
- Corpus — hard rules / capability table / research methodology / won't-do /
  reporting requirements / baselines. zhihu, xhs, tieba, weixin, reddit,
  facebook, dianping, google-maps.

**Wrong-code-returns-200 as a top-ranked rule:** anjuke (rules 2, 3),
fangtianxia (1, 2), dianping (7), weather-cma (three of twelve), 12306 (its
first named trap) — 5 of 18, the most common single failure in the set.

**Closing-list headings, five names for one slot:** "won't do" (`不做的事`),
"can't do" (`做不到的事`), "tried, dead end" (`试过、走不通的`), "never tried"
(`没试过的`), "unverified — don't treat as solved" (`没验证过的（别当已解决）`).
facebook, flights and dianping each carry two of them.

**Cross-site routing:** anjuke↔beike↔fangtianxia (mutual wikilinks),
google-search↔bing (mutual), zhihu→zhihu CLI, weather-cma→aqicn,
xiaohongshu→dianping/Amap/GMaps, weixin→xhs/dianping/Amap, tieba→xhs/dianping/Amap,
dianping→Amap/GMaps/facebook, google-maps→Amap. Edges are mostly one-way:
xiaohongshu names dianping, dianping does not name xiaohongshu.

**Rule-section dilution:** weather-cma carries "the forecast only goes 7 days"
and "the station id is not five digits" among its twelve — capability rows, not
silent failures. weixin is the only skill that tiers its rules (listing layer /
article layer / both layers) and the only one past 12 that stays navigable.

**Lookup data on disk:** one file, `dianping/references/cityid.csv`, 30 rows,
with a "date measured" column empty on every row. Every other table is prose inside
`SKILL.md`.

## What changed, and what did not

Changed: the eight items in commit `d016439` — `metadata.json` and its schema,
baselines to `evals/`, the two site types, the self-check marker, three closing
lists, the cross-site naming ban, the thesis sentence, the hard-rule filter.

**Deliberately not changed:**

- **Reference filenames are half Chinese** (tieba, dianping), half English. No
  tooling problem showed up; ASCII-only would be taste, not a measured need.
- **Site skills are written in Chinese, this document in English.** Nothing
  broke. The rule that did go in is narrower: whatever language a skill uses,
  its self-check marker must be one fixed string.
- **12306 and reddit have no capability table** and read fine without one — both
  are single-entry-point sites. Not evidence the table is optional in general;
  n=2 and both are the same shape.
- **Repairing the cross-site graph** (reciprocity + provenance per edge) was the
  first proposal and was dropped in favour of banning it outright: a routing
  line inside a skill only fires once that skill has been selected, so it repairs
  a bad selection rather than making a good one.

## Not tried

- Whether any of the 18 still works. Nothing was re-run; a skill that has silently
  expired (section 6) would look identical to a correct one in this audit.
- Whether the two-layout split holds for a site that is both — a corpus site with
  a lookup table in it (dianping is closest and was not examined for this).
- Whether `metadata.json` actually removes the wrong-code failure. It is a
  proposal from five instances of the failure, not a measurement of the fix.
