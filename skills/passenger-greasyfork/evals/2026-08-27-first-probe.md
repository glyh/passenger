# First probe of greasyfork.org — the JSON API is a decoy

**Conclusion: the site is one plain fetch away from everything, and the `.json`
route that every third-party client uses currently ignores its query string.**
`SKILL.md` written from this run; no prior version existed.

## Conditions

- Skill version: none — this run created `passenger-greasyfork`.
- Login state: **logged out** throughout. No account was used and none was
  needed; every path returned 200 anonymously. Every "cannot" in `SKILL.md` is
  measured in that state.
- One agent, one lane, one site. No concurrency with other scraping agents.
- Reads only. Nothing was installed, rated, posted or edited.
- Roughly 90 sequential fetches plus one burst of 20 concurrent, over the whole
  session.

## Prior art searched before probing

`gh search code` (the CLI was present and authenticated, so no browser was
spent on GitHub's own search UI). Four queries, two productive:

- `greasyfork.org/scripts.json` → three clients calling
  `scripts.json?q=…&sort=total_installs&per_page=15` (knewbeing/safescripts,
  Alok0811/Eclipsex, MiguelDLM/Custom-news).
- `greasyfork.org/scripts/by-site` → ~15 hits, including violentmonkey and
  scriptcat themselves, plus the `filter_locale=0` and `language=all`
  parameters (ChinaGodMan/UserScripts, shiquda, utags, danydodson) and
  `/scripts/by-site.json` used as a count API (jae-jae/Userscript-Plus).
- `greasyfork.org rate limit 429` and `greasyfork.org per_page` → nothing. The
  legacy code-search API behind `gh` handles multi-term queries poorly; not
  retried in the web UI, so "no public knowledge of the rate limit" is unproven.

**Names taken, then confirmed live: `filter_locale=0` (real, and load-bearing),
`/scripts/by-site.json` (real, and the site's own count table), `page`/`sort`
(real on HTML only). Names taken and found false: `q`, `per_page` and `sort` on
`scripts.json` — every client above is currently getting the same generic
top-100 for every query it makes.** That is the section-1 warning in its purest
form: prior art that 200s with a shape nobody rechecked.

## Numbers

| Measurement | Value |
| --- | --- |
| `scripts.json?q=youtube` vs `?q=tampermonkey` | byte-identical, 190,452 bytes, same 100 names |
| `scripts.json` echo | `term:"*"`, `options.page:1`, `options.per_page:100` regardless of input |
| Listing page size | 100 rows, every listing |
| Listing depth cap | page 20 = 100 rows; page 21 = 0 rows, "No scripts", 200 |
| Cap applies to | `?q=`, `by-site/`, and bare `/scripts` alike |
| `/en/` vs `/zh-CN/`, same `q=youtube` | 60 of 100 rows differ |
| `filter_locale=0` on a busy domain, page 1 | 17 of 100 rows differ |
| `by-site.json` | 794,879 bytes, 45,177 keys, `youtube.com` → 4,619 |
| Table count vs listed rows, three small domains | 4 vs 4, exactly, both with and without `filter_locale=0` |
| `www.youtube.com` by-site listing | 200, 0 rows, indistinguishable from unknown host |
| Library found by searching its exact name | 0 of 15 hits |
| Detail page | 40,806 bytes, all stats server-rendered, no `ld+json` |
| `code_size` vs actual bytes | 96,754 / 97,108 and 269,871 / 264,915 |
| Antifeatures on top-12 rows of a busy domain | 2 of 12, both `Referral links`, neither visible in the listing |
| Rows not updated in over a year, one busy domain | 29 of 100 |
| Rows with no rating | 3 of 100 |
| Total installs across one page | max 6,534,767, median 6,266, min 11 |
| 20 concurrent listing fetches | all 200, 5.1 s, no 429, normal read immediately after |

## What was hit

- **The JSON decoy.** First real probe returned `{model, term, options, query,
  execute}` — a serialized Searchkick query object with the results under
  `execute`. Whether that envelope is deliberate or a leak, the effect is the
  same: 100 real records for a query nobody asked for. Promoted to a hard rule
  on first sighting, per the silent-failure exception.
- **`Accept-Language` deciding the result set.** Found by accident while
  checking a redirect; confirmed by driving the same URL under two language
  headers in one tab. The 60% figure is one query on one pair of locales — the
  *mechanism* is certain, the *magnitude* is one sample.
- **Junk keys in `by-site.json`** — leading dots, an empty-string key, obvious
  malformed `@match` values. Not written into `SKILL.md` beyond one clause in
  the table's `format`: it costs a reader nothing as long as they look a host
  up rather than enumerate the file.
- **`sort=ratings` and `sort=total_installs` returned the same first row.** One
  sample on one domain, so it is not in `SKILL.md`: it may well be that this
  domain's most-installed script is also its best-rated.
- **Rate limiting was never found.** 20 concurrent and ~90 sequential fetches
  passed clean. Recorded as a "haven't tried" rather than as "there is no
  limit", because a ceiling that was not reached was not measured.

## What went into `SKILL.md`, and what did not

In, all as hard rules with self-checks: the JSON parameter decoy; the locale
prefix; `filter_locale=0`; the `www.` key; the page-20 cap; libraries absent
from search; the silent `sort` fallback; `code_size` not being a byte count.

Deliberately left out:

- **Per-page byte sizes** (281–289 KB per listing). A cost, not a rule, and it
  changes with the page.
- **The `options.fields` weighting** (`name^10`, `search_site_names^9`,
  `description^5`, `author^5`, `additional_info^1`). Interesting, and one
  sample of an internal that can change without notice; the useful half — that
  `q=` does not search code — is in the "can't" list instead.
- **`sort=ratings` vs `total_installs` agreeing.** One sample.
- **The `#script-applies-to` selector.** Guessed from the page structure, then
  measured empty — the applies-to list is reachable as
  `a[href*="/scripts/by-site/"]` on the detail page. The working form is in
  `SKILL.md`'s capability table only as a page type, not as a recipe, because
  it was not needed for anything this run did.
- **Any date.** `SKILL.md` carries none; the ones above are here.

## Assertion changes

None — this run was not an evaluation. Nothing here has been A/B'd, and the
call-count baseline for a future comparison is the table above.
