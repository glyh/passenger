---
name: passenger-greasyfork
description: |
  Use when looking for, enumerating, or reading userscripts and their source on
  Greasy Fork — finding what scripts exist for a given site, what a script
  does, who wrote it, how many people run it, and pulling the raw `.user.js`.
  Trigger phrases: "is there a userscript for <site>", "find a Tampermonkey /
  Violentmonkey script that does X", "how does that userscript work", "list
  every script for this domain", "get the source of this script", "what has
  already been solved for this site by someone else".
  Everything here is public and readable without an account; nothing here needs
  a login and nothing here needs rendering. What this site cannot give: the
  install counts are the site's own and cover only installs made through it,
  no listing exposes more than 2,000 entries however deep you page, and
  libraries and unlisted scripts exist but are absent from every search and
  every by-site listing.
---

# Greasy Fork

A Rails site with a complete, server-rendered HTML listing and a JSON API that
looks like the obvious way in and is not: **every listing is in the raw HTML
already, and every query parameter is silently ignored on the `.json` route.**
Nothing here renders, nothing here needs a login, and the whole cost of the site
is in three places where a request you got wrong comes back 200 with a
plausible, complete-looking, wrong list — the wrong language, the wrong 2,000
scripts, or the same top-100 you would have got for any query at all.

## Hard rules

### The `.json` listing endpoints ignore every parameter you pass

`/scripts.json`, `/scripts/by-site/<domain>.json` and friends return 200,
`application/json`, and a well-formed array of 100 complete script records —
for a query that is not yours. `q=`, `page=`, `per_page=`, `sort=` and
`filter_locale=` are all dropped. `q=youtube` and `q=tampermonkey` return
byte-identical bodies: the first 100 scripts by daily installs. Only the URL
*path* is read — the locale prefix and the `by-site/<domain>` segment.

This is the single most expensive mistake available on this site, because the
records that come back are real records and every field in them is right.

⇒ **Use the HTML listing for anything with a query in it** (next rule but one).
The `.json` route is good for exactly one thing: the first 100 by daily
installs, for a domain or for the whole site.

**Self-check:** the response body echoes the query the server actually ran, in
`term` and `options`. `term === "*"` means your `q` was dropped; `options.page`
is always `1` and `options.per_page` always `100` on this route. If you passed
`q` and `term` is not your string, discard the result — do not read `execute`.

### The locale prefix in the path chooses about 60% of your results

`https://greasyfork.org/scripts?q=…` with no locale prefix 302s to a prefix
chosen from the browser's `Accept-Language`. The prefix is not cosmetic: it goes
into the search as a filter, and the same query under `/zh-CN/` and `/en/`
returned 100 rows each of which **60 differed**. Same status, same row count,
same markup — a different search.

⇒ **Always write the prefix**: `/en/scripts?q=…`. Never send a prefix-less
listing URL and trust what comes back, because the browser this runs in is a
human's daily driver and its language header is not yours to assume.

**Self-check:** after the fetch, `resp.url` (or `Page.url()`) must still carry
the prefix you asked for. If you sent no prefix and got one back, the site chose
your result set.

### The default listing hides scripts written in other languages

Even with the prefix pinned, a listing filters by script language unless you
say otherwise. On a large domain, `?filter_locale=0` swapped 17 of the 100 rows
on page 1 — the page is full either way, no message, no gap.

⇒ **Append `filter_locale=0` to every listing URL** unless you specifically want
one language. It is the difference between "the scripts for this site" and "the
scripts for this site that happen to be described in my UI language".

**Self-check:** `metadata.json`'s `by_site_count` table gives the site's own
count for a domain. Fetch the listing twice, with and without `filter_locale=0`,
and compare against that count; on the domains where the two agree, the count
matches exactly.

### A `www.` hostname is not a key, and the empty listing says nothing about it

`by-site/<domain>` keys on the host **as a script declared it**, which is almost
always the registrable domain. `by-site/www.youtube.com` returns a 200 listing
page with zero rows and the words "No scripts" — byte-identical to a host the
site has genuinely never seen — while `by-site/youtube.com` returns 4,619
scripts' worth. A caller holding a URL usually holds the `www.` form, so this is
hit by default rather than by accident.

⇒ **Strip `www.` before building a by-site URL**, and look the host up in
`metadata.json`'s `by_site_count` table first. Subdomains are real keys when a
script named one, so the lookup returns those too rather than assuming the
registrable domain is the whole story.

**Self-check:** an empty by-site listing is only believable when the host's
count in `by_site_count` is also zero or absent. Zero rows against a non-zero
count means the key was wrong.

### Every listing stops at page 20, and page 21 is indistinguishable from the end

`page=20` returns 100 rows; `page=21` returns a normal 200 page that says "No
scripts" — for a search term, for a by-site listing, and for `/scripts` itself,
which has hundreds of thousands of scripts in it. The cap is **2,000 rows per
listing**, and the page past it looks exactly like genuine exhaustion.

The consequence is a coverage limit, not a paging bug: a domain with more than
2,000 scripts cannot be enumerated by paging at all. One measured example — the
site's own table says 4,619 scripts for a popular video domain, and the listing
will hand over 2,000 of them.

⇒ To go past 2,000, **partition the query** — several `sort=` orders reach
different ends of the same set, a `q=` term narrows it, and a subdomain listing
splits it. Do not page deeper.

**Self-check:** if a listing yielded exactly 2,000 rows, treat it as truncated,
not complete. Compare against `by_site_count` for the domain before reporting
coverage; a shortfall against that number is the cap, not a fetch failure.

### Libraries and unlisted scripts are absent from every search

Search and by-site listings are filtered to public scripts by type. A library
is not one, so a library **never appears in search results even when you search
its exact name** — measured: searching a library's exact title returned 15 hits,
none of them it. There is no error and no note; the list is simply of other
things.

⇒ Libraries have their own listing at `/en/scripts/libraries`. A script id you
already hold always resolves directly at `/en/scripts/<id>` and
`/scripts/<id>.json`, whatever its type.

**Self-check:** before concluding "this is not on the site", fetch the id or the
name against `/en/scripts/libraries` as well. "Absent from search" is a fact
about the search filter, not about the site.

### An unrecognised `sort` value falls back to the default ranking

`?sort=nonsense` returns the same first row as no `sort` at all — daily
installs, descending. A misspelled sort key therefore produces a list that is
ordered, plausible and not the order you asked for, which matters most when the
sort *is* the question ("the newest", "the most installed").

The values that work: `daily_installs` (the default), `total_installs`,
`ratings`, `created`, `updated`, `name`.

**Self-check:** read the sort field off the first two rows — the listing carries
`data-script-total-installs`, `data-script-created-date` and
`data-script-updated-date` on every row — and confirm they are ordered by the
key you asked for.

### `code_size` is not the size of what you downloaded

The `code_size` field in the JSON records is close to, and not equal to, the
byte length of the file at `code_url` — two scripts measured 96,754 against
97,108 bytes and 269,871 against 264,915. It is not a completeness check, and a
truncated download will pass a loose comparison against it.

**Self-check:** a complete userscript starts with `// ==UserScript==` and
contains the closing `// ==/UserScript==`. Check those two, not the length.

## What each page type gives, and what it costs

Everything below is one plain fetch of the raw HTML or JSON. **No page type on
this site requires rendering**, and none requires a login.

| Path | What it gives | Rendering |
| --- | --- | --- |
| `/en/scripts?q=…&filter_locale=0` | search, 100 rows/page, capped at page 20 | no |
| `/en/scripts/by-site/<domain>?filter_locale=0` | every public script declaring that domain, same cap | no |
| `/en/scripts/libraries` | libraries, which are in no other listing | no |
| `/en/scripts/<id>` | one script: description, stats, antifeatures, applies-to | no |
| `/scripts/<id>.json` | the same script as 23 clean fields | no |
| `/en/scripts/<id>/code` | the source with syntax highlighting, in `<pre>` | no |
| `code_url` on `update.greasyfork.org` | the raw `.user.js`, no auth, `text/javascript` | no |
| `/en/scripts/<id>/versions` | version history | no |
| `/en/scripts/<id>/feedback` | discussions and reviews | no |
| `/scripts/by-site.json` | domain → script count, whole site (see `metadata.json`) | no |

### The listing rows are the cheap read, and they carry the code URL

Each result is an `li[data-script-id]` whose `dataset` holds the whole row —
`scriptName`, `scriptAuthors` (a JSON object of id → name, as an attribute
value), `scriptDailyInstalls`, `scriptTotalInstalls`, `scriptRatingScore`,
`scriptCreatedDate`, `scriptUpdatedDate`, `scriptType`, `scriptVersion`,
`sensitive`, `scriptLanguage`, `cssAvailableAsJs`, and **`codeUrl`**.

That last one is what makes this site cheap: **you can go from a domain to
downloaded source in two fetches**, listing then `codeUrl`, without opening a
single detail page. Read the detail page only for what the row does not carry —
the long description, the ratings breakdown, the applies-to list, and
antifeatures.

    const d = new DOMParser().parseFromString(html, "text/html");
    const rows = [...d.querySelectorAll("li[data-script-id]")].map(li => ({...li.dataset}));

**Self-check:** run that pair of lines alone against page 1 before wiring it into
anything. A page that is not truncated yields exactly 100 rows, and every row
has a `codeUrl`; a row without one is a CSS-only entry, not a parse failure.

## Where the good material is

The default order is **daily** installs, which ranks a script that was promoted
this week above one that a million people have been running for years. On a
popular domain the first page is dominated by freshly-published all-in-one
downloaders: across one such page, total installs ran from 6.5M at the top to 11
at the bottom with a median of 6,266, so the ranking is not telling you what is
established. `sort=total_installs` is the better first look for "what do people
actually use", and `sort=updated` for "what still works".

**Antifeatures are the site's own spam signal, and they are only on the detail
page.** The listing markup contains no antifeature marker at all — verified by
grep over the listing HTML. Two of the top twelve rows on a popular domain
declared `Referral links` on their detail page, and nothing about their listing
row said so. If spam matters to the answer, the detail fetch is not optional.

Other signals worth reading off the row before spending a fetch:

- **`scriptUpdatedDate` is the strongest single filter.** On one busy domain,
  29 of 100 rows had not been touched in over a year — on a site whose targets
  change their markup constantly, that is close to a liveness test.
- **Ratings are sparse, not absent.** Only 3 of 100 rows had no rating at all,
  so `scriptRatingScore` is usable as a tiebreak rather than as a filter. The
  detail page splits it into good/ok/bad counts, which is the honest version.
- **`sensitive` is on every row.** Adult-content scripts are indexed and
  excluded from default listings; the attribute is how you tell that the one you
  are looking at came back anyway.
- **`scriptAuthors` is a JSON blob inside an attribute.** Parse it; do not
  regex it, and do not read the author name out of the link text when the row
  already has the id.

## Won't

- **Read-only.** No account is needed for anything above, so nothing here
  installs, rates, reports, posts feedback, or edits a script — even where a
  human's session in this browser could.
- **Do not fetch source in bulk to redistribute it.** Scripts here carry
  licences, and `license` is a field on every JSON record; quote it when you
  quote the code.

## Can't

Measured logged out, which is the only state any of this needs:

- **More than 2,000 rows out of one listing.** The cap is the fourth rule.
- **Server-side full-text search of script source.** `q=` searches name,
  site names, description, author and additional info — the field list is in
  the `options.fields` echo on the JSON route. Searching code means downloading
  it.
- **A stable "all scripts for this domain" count from the listing.** The count
  comes from `by-site.json`; the listing will not tell you how many it is
  holding back.
- **Anything about who installed a script.** Install counts are totals, and
  cover only installs the site itself served.

## Haven't tried

- Whether a logged-in session changes any listing — in particular whether the
  sensitive filter or the 2,000 cap moves for an account that has opted in.
- The `/scripts/<id>/feedback` discussion markup: the page is 51 KB and parses,
  but the selector for an individual discussion was not worked out.
- Whether `sort=` values combine with a `q=` relevance ranking or replace it.
- The non-JS listings (`/en/scripts/by-site/<domain>?language=css`) and whether
  `cssAvailableAsJs` means what it appears to.
- Rate limiting: 20 concurrent listing fetches and roughly 90 sequential ones
  passed with no 429 and no slowdown, so the ceiling was never found. Do not
  read that as "there is no limit".

## Reporting requirements

A conclusion drawn from this site discloses:

- **Which listing produced it**, with the locale prefix and `filter_locale`
  as they were sent. Without those two, a result set is not reproducible.
- **Row count against the site's own count** for the domain, when the question
  was "what exists for this site" — and explicitly whether the 2,000 cap was
  reached.
- **That searches exclude libraries and unlisted scripts**, whenever the answer
  is a negative one ("there is no script for this").
- **Antifeatures**, when recommending a script, or that the detail pages were
  not fetched and so spam was not checked.
