---
name: passenger-skill-authoring
description: |
  Use when writing a scraping skill for a specific website, revising one, or
  evaluating whether an existing one earns its keep. Trigger phrases: "write a
  skill for <site>", "we keep re-learning this site", "this site's skill did not
  help", "is this skill worth keeping", "A/B two versions of a scraping skill".
  Covers what to probe for, which findings to record, how to phrase them, where
  a site's lookup tables and a run's evidence are kept, and how to measure
  whether the skill helped.
  Does NOT cover performing a single scrape, and does NOT cover any individual
  site's mechanics — those belong in that site's own skill. For driving the
  browser at all, use `using-passenger` instead.
---

# Writing a scraping skill for a site

**This document's most common failure is not a missing rule. It is a rule that
was not recalled at writing time.** Mechanism leaks into `description`, and body
text gets written as revision history, in files whose author had read this
document first — and both of those already had a rule.

⇒ **Re-read section 10 line by line before committing the file.** Do not rely on
remembering the rules. A checklist is worth something at the moment it is
executed, not at the moment it is written.

## 0. Naming and `description`: these are for *selecting* the skill, not using it

### Name: `passenger-<site>`

A site's scraping skill is always named **`passenger-<site>`** — both the
directory name and the frontmatter `name:` (e.g. `passenger-reddit`,
`passenger-xiaohongshu`).

The prefix exists to **avoid collisions**: the same site name may already be
taken by an unrelated skill (an official API client, a CLI wrapper). The prefix
keeps them from colliding rather than renaming after the fact.

**The only exception is this document.** In `passenger-skill-authoring`,
`skill-authoring` is not a site name — it is the family's meta-document, sharing
the prefix so it sorts with the skills it governs. Otherwise, whatever follows
`passenger-` is a site.

### `description` holds exactly three things

`description` is **how a skill gets selected**, not a summary written after the
body. It contains only:

1. **What it can do** (capability)
2. **When to use it** (positive trigger — include the phrasings a caller
   actually types)
3. **Where its boundary is** — stated in the first person, as a fact about this
   site: "overseas house prices are not here", "this site cannot give distance
   or routing". Never the destination; see below.

**Mechanism never goes in `description`:** selectors, field names, URL shapes,
evidence for silent failures. All of it stays in the body, which is in front of
the reader the moment the skill loads. Duplicating it means maintaining two
copies; edit the body, forget the description, and you have a lie that raises no
error and that nobody discovers until the description and the measured body
contradict each other in front of a user.

**Test after writing a description:** does this sentence help me *choose* this
skill, or help me *use* it? If the latter, move it into the body.

### A site skill never names another site

**No "use X instead", no "X is better for this", no link to a sibling skill.**
Unruled, these accumulate into a hand-maintained graph between every pair of
skills that touch one subject, and that graph fails three ways at once.

- **It fires too late to help.** A routing line inside skill A is only read once
  A has been selected. If A was the wrong choice, selection already failed and
  the line is repairing the damage, not preventing it.
- **The claim cannot be verified by the skill making it.** "This source has the
  best rent samples of the three" is an assertion about three sites written in
  one site's description, backed by nothing the reader can reach. Section 6
  applies with full force and there is no way to run it.
- **The edges are one-way and stay that way.** Skill A routes to B; B has never
  heard of A. A caller who lands on B never learns the boundary exists.

⇒ A description carries only what **one run against this one site** could
establish. "Overseas house prices are not here" is that. "For overseas house
prices use X" is not.

### Comparisons live in one document per *question*

The routing knowledge is real and deleting it would lose it — so it moves, whole,
to where it can be maintained and verified: **one document per question the
sites compete to answer** — house prices in a country, web search, local
restaurant reputation — owned by whoever ran the comparison, with the comparison itself recorded in an `evals/`
file covering **the whole family** rather than one member (section 8).

Per *question*, not per site, because that is what the caller is actually holding
when they choose. Nobody arrives wanting a particular property portal; they
arrive wanting a rent number, and a document named for the rent number is
selectable while a web of cross-links between three site skills is not.

**One carve-out: two skills reaching the same site.** When a site is reachable
two ways — an official API client and a scrape of its web version — one of them
must say which is primary and when to fall back, because otherwise the caller
faces two descriptions of the same site and has no basis to choose. That claim
is first-person (the cap you hit is yours to measure) and there is exactly one
edge, so it does not become a graph. This does not extend to a second *site*.

### Two kinds of site, and they do not want the same document

**Decide which of the two you are writing before you choose a layout.** They do
not want the same sections, and the split is structural rather than stylistic:

- **A lookup** — one question, one query, a table back (weather, air quality,
  flights, trains, house prices, a government gazette). Section 3 is the whole
  ballgame: a wrong code is the failure mode, and the capability table plus the
  recipe are most of the file. **Section 5 does not apply**: there is no
  signal-density question when the site returns one number.
- **A corpus** — human text of wildly varying quality (forums, review sites,
  social feeds, Q&A). Section 5 and the coverage numbers are where the value is;
  a purely mechanical version of one of these leads its reader to collect spam
  and conclude that is all the site has.

⇒ A lookup skill with a methodology section is padding; a corpus skill without
one is a scraper.

Every section below asks the same question: **what did you hit this time that
the next person will hit identically?** Things that are hit *and recognised*
(errors, 404s, timeouts) need no entry. **Things that are hit and not
recognised** are what to write down.

Write only what is true of that site. How the tool itself works, and generic
scripting traps, are not here — and **must not be restated or linked to from the
produced skill**. They have their own owners, and both copies and pointers rot.

---

## 1. Find the cheapest read — other people's first, then your own probes

Taking a site from "render plus 25 scroll rounds" down to "fetch the HTML once"
justifies the whole skill on its own. It is also a cost **only the first prober
pays**: everyone after either follows the recipe or re-derives it — and on a
site of any size, somebody outside this repo has already paid it.

### Search for prior art before the first probe

⇒ **Do not start scraping straight away. Spend the first ten minutes looking
for someone who has already worked the site out.** The endpoint, the parameter
that must not be omitted, the header the site signs, the field that means "it
worked" — these are things a stranger's code *names*, and naming them is the
expensive half. A probe ladder run blind can spend an hour rediscovering a path
that is written down in public.

Where to look, cheapest first:

1. **GitHub code search, not repository search.** Search for the API host and a
   path fragment (`api.<site>.com/`), or for a token the site's own page emits
   (`__INITIAL_STATE__`, `x-s`, `sign=`). The repository name almost never
   mentions the site; the request URL inside it always does. **An abandoned
   repo is still useful** — a dead client names endpoints and parameters even
   when its code no longer runs.
2. **Greasefork and the userscript indexes.** A userscript runs *inside the
   logged-in page*, which is exactly the position this tool puts a caller in.
   Scripts that expand truncated bodies, strip an overlay, or re-add a download
   link are a tested selector list plus a working DOM trick — tested by users
   who file an issue the week it breaks, which is a freshness signal nothing
   else on this list has.
3. **An old wrapper on PyPI/npm, or the site's own app/API docs.** Unmaintained
   ones still name parameters and enum values, and enum values are section 3's
   whole problem.

**Take the names, not the code.** Endpoint paths, parameter names, the marker
field, which header carries the signature, which page type has JSON in it.
Copying a signing routine or a selector block wholesale imports a bug you
cannot see and did not write.

⚠️ **Prior art is a hypothesis with a date on it, and the date is not today.**
A path that has moved usually does not 404 — it 200s with a shape nobody
checked, which is section 2's failure mode arriving through the front door.
**Self-check: every name taken from someone else's code must be confirmed
against the live site in this session before it reaches `SKILL.md`** — the
endpoint returns the field you expected it to, under this account's login
state. Write the confirmed finding first-person, as something this run
measured. **A third-party repository is not a citation `SKILL.md` can rest on**:
it is unversioned, it can vanish, and a reader who follows it reads a claim
nobody here checked. The URL and the date belong in `evals/` as provenance
(section 8), with the site skill stating only what was verified.

**Timebox it and record the outcome either way.** Two searches turning up
nothing is itself a finding worth one line in `evals/` — otherwise the next
author spends the same ten minutes proving the same absence (section 8,
negative results). Then probe.

### The probe ladder

**Try in order; stop at the first that holds:**

1. **Does the raw HTML contain the site's own JSON?** `__INITIAL_STATE__`,
   `__NEXT_DATA__`, an inline `application/json`. If yes, you are done: one
   fetch, and the fields are more complete than what the page displays.
2. **Does `<head>` carry a `<link rel=preload>` pointing at the data endpoint?**
   Then it is fetch HTML → extract that link → fetch once more. Two hops, still
   no rendering.
3. **Is there a JS-free legacy/mobile/`.json` endpoint?**
4. Only if none of the above: render.

**⚠️ Record the conclusion per page type. Do not generalise across the site.**
On one site, search results may require rendering while detail pages, user
pages, and the recommendation feed all have their data in the raw HTML.
**Write it as a table of which page types need rendering** — that is the first
thing a reader of the skill needs.

## 2. Hunt for silent failures — this is the skill's core asset

**Definition: returns 200, well-formed, structurally complete, and the content
is wrong.**

This differs from an error. A model handles errors on its own. **A model does
not recognise a silent failure** and will write it into its conclusions as real
data.

**Do not wait for these to appear. Probe for the shapes below.** This list was
produced by hitting them, not by imagining them:

| Shape | What it looks like |
| --- | --- |
| **Missing parameter still returns 200** | one token/signature short; the page returns normally, the key field is simply absent |
| **Returns a different object** | query city A, get city B; query a place, get the previously queried one; no data falls back to the parent region |
| **Same name, different thing** | one selector points at different things on two screens; one class reused across different buttons |
| **UI language changes the selector** | `aria-label`-style attributes change wholesale with the language parameter; silently matches nothing in the other language |
| **Content has been machine-translated** | the body is MT, and the "original language" label is itself wrong |
| **A number does not mean what it looks like** | "price" is really a price *band*; "rating" is weighted |
| **Paging/scrolling empties what you read** | container and height remain, children are gone — **a count-based self-check still passes** |
| **Body truncated behind "expand"** | the truncated part is **not in the DOM**; changing selectors or adding waits does nothing |
| **Past the end, a fixed fallback page** | paging beyond real depth returns **the same** query-irrelevant page every time; **item counts are still full**, so count-based checks all pass |
| **Same field, different item count per subtype** | an identically-named array has one fewer entry in another category (no "ingredients"); **index-based access shifts everything** — access by name |
| **Large items with no content** | an 11 KB response holds only id and title; address and rating are absent. **Do not pick a data source by size** — look at the keys first |
| **Empty recall without an error** | the keyword appears zero times in the results; the same query returns different result sets twice |
| **Throttling without an error** | navigates the tab away, or returns a page whose tone is off — reads like "there was never anything here" |
| **How quota accrues** | Per endpoint? Per account? Does it reset across sessions and lanes? **Can you switch endpoints and continue after hitting it?** |

### Every silent failure needs a cheap self-check attached

**This is the most important sentence in this section.** Writing only "⚠️ it can
return data for the wrong city" is half a finding: the reader knows to be
careful but not what to be careful *about*. Supply **an action that runs on the
spot and returns a verdict**:

- After fetching, confirm the returned city/place name is the one you asked for.
- Three components should sum to the total; if they do not, you have the wrong
  field.
- Does `body` end with the word "expand"? Then you have half the content.
- Check `resp.status`, not just whether a body came back.
- Is the marker field present (`noteDetailMap` and similar "present means it
  worked" flags)?

**Pick criteria that survive content changes. Length thresholds are almost
always wrong** — the truncation point moves with post length, and an empty
result can be the same length as a real one.

### Mark every self-check with the same string, so the audit is a `grep`

**Open every self-check with the same literal string throughout a file** —
`**Self-check:**`, or its equivalent in whatever language the skill is written
in, but one spelling per file. Then the audit is one line, and it belongs in the
pre-commit pass:

    n=$(grep -c '^### ' SKILL.md); m=$(grep -c 'Self-check' SKILL.md)
    [ "$m" -ge "$n" ] || echo "$((n - m)) rule(s) with no self-check"

The rule above is the one this document calls its most important sentence, and
it is also the one most often skipped: roughly two rules in five end up with no
self-check at all. A prose checklist is recalled rather than run, and a marker
that varies its phrasing cannot be counted even by someone trying.

### A number inside a rule is a threshold, not a record

Numbers earn their place in `SKILL.md` only where **a check compares against
them** — "got 146 of 156, and the gap is deletions" is what makes "you tripped
the paging bug" readable. Put that number *in the self-check that uses it*, not
in a table at the foot of the file, which is the place least likely to be open
when the run goes wrong. Everything else the run measured — call counts,
timings, byte sizes, hit rates — is evidence for the *next run*, not for this
one, and goes to `evals/` (section 8).

Two of those thresholds have to be stated as consequences or they read as
trivia:

- ⚠️ **A field with a low hit rate needs its consequence spelled out.** "Only
  12 of 37 have a permalink" is a number; "so the dedup key needs a degraded
  branch, or the batch gets dropped" is the rule.
- ⚠️ **Say which shortfalls are not failures.** Image-only posts never had body
  text. Unsaid, the next person fixes something that is not broken.

### If it is not a silent failure, it is not a hard rule

⇒ **The filter: does following it wrong produce a well-formed wrong answer?**
No → capability table, or a line of the recipe.

The hard-rules section is the skill's core asset and also the easiest place to
put anything true about the site. "The forecast only goes 7 days" is a
capability row; "the station id is not five digits" is a line of the recipe.
Neither returns 200 and lies, and each one that gets in dilutes the rules that
do.

⇒ Past roughly eight rules, **tier them by where the caller is in the flow**
rather than by discovery order — listing-layer, article-layer, both-layers. It
is what keeps a long rule list navigable, and discovery order never is.

## 3. A lookup table is a silent failure with rows: `metadata.json`

**A wrong code is not an error on these sites, and that makes a lookup table
something other than reference data.** The caller holds a **human name**
— a city, a station, a district — and the site wants **its own opaque code** for
it. The gap between the two is not derivable, so it gets guessed; and on these
sites the wrong code comes back 200: the national homepage, the parent region, a
well-formed empty table with no message on it, or simply somebody else's city.
It is the most common single failure a site skill has to warn about.

That fixes what a lookup table *is* here, and it is not reference data. **The
table and its failure mode are one object**, and four things are part of the
datum rather than notes about it:

1. **Absence has two meanings.** "The site does not have this city" and "we
   never looked up this city" are indistinguishable in a bare table, and the
   first is a conclusion while the second is nothing at all.
2. **A row can be a guess.** A slug written from the site's naming pattern and a
   slug that was actually opened are byte-identical once written down. This is
   section 6's problem in data form, and it is worse there: prose can hedge, a
   table row cannot.
3. **What a wrong key does** is not the same on two sites, and it decides what
   the caller's check has to look for.
4. **The check that proves the key was right** — usually the reverse lookup, or
   the field in the response that echoes the key back.

A CSV holds none of the four. The most it offers is a date column, which is why
those end up empty: a date alone says neither what it certifies nor what happens
when the id is wrong, so there is no reason to fill it in.

⇒ **Lookup tables go in `metadata.json` at the skill root, against
`schema/metadata.schema.json` in this directory.** One file per site, one shape
across every site, so that reading a table is a fixed flow rather than a thing
each skill invents.

```json
{
  "site": "anjuke",
  "tables": {
    "city": {
      "describes": "prefecture-level city -> this site's city slug",
      "source": "derived",
      "on_mismatch": "silently degrades to the national homepage; page structure is normal",
      "verify": "open /market/<slug>/ and check the city name in the page title",
      "coverage": "partial",
      "measured": "2026-08-26",
      "entries": [
        { "key": "Yuxi", "value": "yuxi", "verified": true },
        { "key": "Mengzi", "value": "mengzi", "verified": false, "note": "written from the naming pattern, never opened" }
      ]
    }
  }
}
```

`source` is `measured` (every row hit), `derived` (some rows written from the
naming pattern — `verified` per row says which), or **`upstream`**.

### `upstream`: when the site publishes the table itself, ship the query

A local copy of a table the site maintains is always a stale subset, and it goes
stale **silently** — which is the whole failure this section exists to remove,
reintroduced by the fix. So an `upstream` table carries no `entries` at all:
`url`, `format` (the record shape, so the extraction can be written without
fetching first), `size` (so nobody reads 168 KB into context), and `query` — a
runnable one-liner that pulls out the rows wanted **and** does the reverse
lookup, because the reverse lookup is the self-check.

### Validate before committing, and read the summary even when it passes

    node skills/passenger-skill-authoring/scripts/validate-metadata.mjs \
         path/to/passenger-<site>/metadata.json

It exits non-zero listing every problem at its JSON path. On success it prints a
per-table line, and **that line is worth reading**: it names the `derived` rows
and the `partial` coverage, which are the two things a reader mistakes for
measured fact.

### `SKILL.md` states the flow once and never the contents

The prose says *which table to consult and that guessing is the failure* — one
sentence — and stops. It does not restate rows, because that is section 0's two
copies rotting, with the added twist that the stale copy here is the one a human
reads while the script reads the other. The `on_mismatch` and `verify` strings
are the exception in the other direction: they are properties of the site, so
they earn their hard rule in `SKILL.md` too, and the table is where they are
attached to the data that triggers them.

## 4. Account for reading and driving separately

**Reading** (fetching HTML, hitting endpoints) costs nothing. Use it freely.
**Driving** (clicking, typing, scrolling) spends account risk and throttle quota.

- **Put driving in the last step of the task.** Being cut off mid-way then costs
  only that step.
- Record **how this site's quota accrues** (last row of section 2). This decides
  whether hitting the limit means "switch endpoints and continue" or "done for
  today" — a large difference.
- If the site uses the user's own login, **write "read-only" into the SKILL**
  and list what must not be touched.

**A site using a login needs the login itself documented**, which is knowledge
belonging to no single page:

- **Who logs in.** QR-code and SMS flows must be completed by hand. **Do not
  script the login flow** — it is the most bot-like sequence in the whole
  session.
- **Whether logging in trips risk control, and how to recover.** A site can flag
  the account and restrict web access on merely *opening the login page*, with
  the restriction lifting by the next day. ⇒ Write it as an executable
  instruction — "if this trips, retry the next day; do not retry repeatedly the
  same day" — not as "there is risk, be careful".
- **How to tell the session is still valid.** Prefer the site's own marker
  fields (`logined`, `loginCode`). They are harder than "did the URL redirect"
  and far more reliable than body length.

⚠️ **Capability boundaries flip wholesale with login state.** A "this site
cannot reach X" measured while logged out may become three readable page types
once logged in. A skill written from a logged-out session can be **wrong for a
whole chapter**, and confidently so. Every "cannot reach" must state **which
state it was measured in** (section 10).

## 5. Where the good material is matters as much as how to fetch it

**Corpus sites only** (section 0). A lookup site returns one number and has no
signal-density question to answer.

A purely mechanical skill leads people to collect garbage and conclude that is
all the site has. Write down this site's signal-to-noise patterns:

- **High-traffic areas are not necessarily high-density.** A million-member
  "reviews" group may be all merchant ad spam, while a few-thousand-member
  topic group has the highest hit rate.
- **Review volume ≠ quality.** The venue or source with the most reviews often
  has the most problems.
- **Which metric actually indicates "this one is useful"** (saves > likes;
  number of people agreeing > one long comment).
- **How to tell first-hand from second-hand:** the stable shape of native ads
  (body is a funnel, contact details at the end), content-farm markers, traces
  of machine-translated reposts.

## 6. Honesty: a recipe derived from an observation carries bugs

You observe a **phenomenon**, then write code from it. That code has not run,
**and probably has a bug.** Three failures in one session came from exactly
this: an invented selector, a guessed field index, and a base64 encoder that
throws `RangeError` at a few hundred KB — whose primary use is precisely large
files.

⇒ **Separate "what was measured" from "what was written from it"**, and state in
one sentence which part has not run.
⇒ **Give a verification entry point**: run that fragment alone, print one value,
check it against expectation, then wire it into the main flow.

### The harder case: **once true, silently now false**

The rule above is about recipes that were never run. This is the opposite: it
**was run, and was correct**, but the site changed or a layer underneath the
tool was replaced — and **nothing announces that it expired.** Unlike an
invented recipe, this one had evidence, so the reader (including you) has no
reason to doubt it.

They look like: a warning about an extra field the runtime no longer returns; an
API name in a previous runtime's spelling (`Page.APIRequest` where it is now
`Page.request`); a code block in the language the project has since left. Each
was correct when written, and each fails silently — following it returns
`undefined`, and `undefined` at that line looks exactly like "this page does not
have that".

⇒ **Every assertion about *how the tool behaves* must state what it was measured
against** — not just login state (section 4) but the tool's or site's version or
shape at the time.
⇒ **When revising a skill, actually run every recipe you touch.** Running finds
this class; re-reading does not, however many passes.
⇒ A cheap self-check: **grep the body for spellings that should no longer
exist** (old field names, old API names, the previous language's syntax). Faster
than re-reading, and it targets this class specifically.

## 7. Committing the file

### Style: describe the site as it is now, not what you changed

A skill is **a description of the current state, for the next person.** It is
not a revision log for you. Revising an existing skill is where changelog voice
creeps in. The forms it takes:

- "the previously recorded 'these two page types are unreachable' **has been
  overturned**"
- "**first attempted 2026-08-24**, restricted; **retried 8-25**, succeeded"
- "originally we worried this needed a 'measured on one category only' caveat;
  **it can now** be treated as a general structure"

The reader does not know what "previously" was and does not care which day it
changed. They want to know **what the site looks like now.** Rewrite every
sentence as a property of the site: *logging in trips risk control; if it does,
retry the next day.* One sentence, no timeline, executable.

**`SKILL.md` carries no dates at all.** Provenance is still required — a number
nobody can date cannot be judged expired — but it now attaches to the two files
that hold the numbers: `measured` in `metadata.json` (section 3) and the run's
own file in `evals/` (section 8). That makes the rule mechanical rather than a
judgement call about whether this particular date is a change record:

    grep -nE '[0-9]{4}-[0-9]{2}-[0-9]{2}' SKILL.md    # must print nothing

**Test: delete every date and every "previously / originally / now changed to".
Do the sentences still stand?** If not, it was a changelog.

**Deleted, not lost.** What comes out here is the run's evidence, and it is
worth keeping — in `evals/`, which is section 8. "Overturned", "first attempted,
then retried", "we used to worry about" are all correct sentences *there*.

### File layout

**`SKILL.md`:**

- **A thesis sentence, before anything else.** One sentence saying what this
  site *is*, and one saying what shape its failures take — "almost everything
  here has a clean JSON endpoint; the whole cost is in the parameters, and most
  of the rules below are about that one thing." Eight rules then read as one
  idea. Open straight into the rule list instead and the file reads as a
  checklist, which is the property you are trying not to have. It costs a
  paragraph.
- **Hard rules** — silent failures, one per section, **each with its own
  self-check** carrying the threshold it compares against (section 2).
- **Capability table** — which page types need rendering, which come back in one
  fetch; what this site does and does not yield.
- **Method** — the "where the good material is" content from section 5. **Corpus
  sites only** (section 0).
- **Three closing lists, and they are not one list** (see below).
- **Reporting requirements** — what a conclusion must disclose (coverage, which
  entry point was read, provenance of any number quoted).

**No baseline section.** Thresholds live in the self-checks that use them; the
run's raw numbers live in `evals/`. Section 2, and section 8.

**`metadata.json`:** the site's lookup tables, against this directory's schema.
Section 3.

**`references/`:** one file for **what most runs do not need** — a page type with
mechanics only some tasks reach, this site's own scripting traps. Not one file
per page type by reflex. A skill stays readable well past 300 lines with each
recipe sitting next to the rule that cites it, and splitting earlier separates
the two for no gain. Split when the file stops being readable straight through,
not before.

**`evals/`:** one file per run — the datapoints behind everything above, and,
with baselines moved here, the only place in a skill where a date appears
outside `metadata.json`. Section 8.

### "Won't", "can't" and "haven't tried" are three lists

These get written as one list, or as two under names that do not say which is
which. They have opposite consequences for a reader:

| List | What it is | What the reader does |
| --- | --- | --- |
| **Won't** | policy — read-only, no voting, no posting under the user's login | obey it |
| **Can't** | measured — this site does not yield that, and here is the state it was measured in | route around it |
| **Haven't tried** | unknown — nobody has run it | **try it** |

Folded together, the third one is read as a prohibition and never gets tried
again, which is the exact opposite of what writing it down was for. Keep three
headings.

⇒ **The "haven't tried" list is the queue for the next evaluation** (section 9).
That is what it is for, and it is the reason it must not read like the other two.

## 8. `evals/`: where everything section 7 deletes goes

Section 7 makes `SKILL.md` a description of the site as it is now, with the
history stripped out. That rule is right, and it throws away information that
cost a run to obtain: the probe that found nothing, the numbers the next run
needs to compare against, the reason a rule that reads as arbitrary is there,
the two assertion rewrites that both failed. Deleted from `SKILL.md`, they are
gone — and the next reviser re-derives them, or re-walks the same dead end.

They go in **`evals/`**, one file per run. **A site's skill therefore has two
documents with two readers**, and confusing them is what produced the changelog
voice section 7 is about:

- `SKILL.md` is read **at scrape time**, by an agent doing a job. It reads as
  one fluent recipe — what this site is, what to do about it. No dates, no
  "previously", no account of who learned what when.
- `evals/` is read **at revision time**, by whoever is changing the skill. It is
  the datapoints. It is a log, it carries dates, and it keeps findings that
  contradict each other.

⚠️ **`SKILL.md` must not link to `evals/`.** A cross-reference drags the log
into scrape-time reading and the recipe stops being one. The pointer runs the
other way: an eval file names the sections it changed.

### One file per run: `evals/YYYY-MM-DD-<slug>.md`

Not one growing file — per-run files are what make "compare two runs" and "read
the last three" cheap. Each holds five things:

1. **Conditions.** Skill version (commit is enough), login state, which
   questions were asked, how many agents ran and against which sites. Without
   these the numbers below are unreadable, and section 9's contamination is
   undetectable after the fact.
2. **Numbers, per question — this is where baselines live.** Calls, tokens,
   failed calls, wall clock, and everything the run measured about the site:
   items per scroll round, response sizes, per-field hit rates, how long a
   render took. Section 9's primary metrics are in here too. `SKILL.md` keeps
   only the handful of numbers a self-check compares against (section 2); the
   rest are evidence for the *next* run rather than for this one, and a table of
   them at the foot of a recipe is the least likely thing in the file to be open
   when a run goes wrong. Without this section recorded, "it got faster" is a
   feeling.
3. **What was hit.** Every silent failure, dead end, throttle, and surprise —
   *including the ones not written into `SKILL.md`*, each with one sentence on
   why not (seen once; or unclear whether it was the site or us).
4. **What changed in `SKILL.md`, and what deliberately did not.** One line each.
   **The deliberate omissions are the valuable half**: without them the next run
   rediscovers the same thing and has no way to tell it was already judged and
   dropped.
5. **Assertion changes**, if the run was an evaluation — including rewrites that
   failed and why (section 9 has two worked examples of exactly this).

### Promote on a second sighting, except for silent failures

A finding from one run is a datapoint, not yet a rule. **What earns a line in
`SKILL.md` is a second run hitting the same thing** — timings, throttle
thresholds, "this endpoint is slow", "the feed looked shuffled" are all things a
single run cannot tell from noise, and a `SKILL.md` full of one-off observations
is the recipe getting slower to read for no gain.

**Silent failures are the exception and go in on first sighting.** They are
cheap to state and expensive to hit, and a reader who has not been warned writes
the wrong data into a conclusion (section 2). Everything else waits for
confirmation, in `evals/` until then.

### Negative results are a line each, and only the log can hold them

"The `.json` endpoint 404s." "No `__NEXT_DATA__` on the detail page." "Scrolling
past round 12 adds nothing." "Nothing on Greasefork; the two GitHub clients both
predate the current signing scheme." These are never sentences `SKILL.md`
should carry — it says what to do, not the list of things that do not work —
but re-checking each of them costs a probe. The log is where a probe gets paid
for once.

### Read them before revising

**Before touching a site's `SKILL.md`, read its `evals/` newest-first.** It is a
handful of short files, and it is the only place that answers "why is this rule
here" and "has this already been tried". Section 6's harder case — once true,
silently now false — is also read from here: a rule whose only eval entry is
several runs old, on a version of the site nothing since has confirmed, is the
first place to point a re-run.

---

## 9. Evaluating a scraping skill: the metric is detour cost, not answer correctness

A/B-ing an old and new version is right, but **metric and scheduling are two
halves of one thing: schedule it wrong and the numbers are contaminated; pick
the wrong metric and you cannot read a conclusion even from clean numbers.**

### Do not score on answer correctness

Pass/fail assertions come out **identical on both sides of an A/B**, with almost
no discriminating power, because the model routes around a stale description on
its own — discovering unaided that a timetable cannot be read with `fetch`, that
air quality falls back to the parent region, that listing-price percentages drop
their sign.

What does discriminate is **call count and tokens**. A skill that stops making
the agent rediscover a silent failure roughly halves both.

⇒ **Primary metrics: call count, tokens, failed-call count.** Assertions are a
backstop for hard errors only.

A skill's value is not "makes the answer correct" — the model can usually
recover on its own. It is "nobody has to step in the same hole again". **Scoring
on correctness produces the wrong conclusion — "this skill is useless" — and
then deletes the very holes most worth recording.**

Two adjacent traps:

- **Assertions themselves frequently have bugs**, and flag behaviour that was
  correct. Read the evidence before believing one.
- **Do not use test questions whose answers are already written in the skill
  body.** Re-test with an example the skill never mentions before it counts.

### Assertions weld old policy into the evaluation

Distinct from "assertions have bugs" and worth its own entry: **an assertion
freezes the skill's policy at the time it was written, and once that policy is
overturned it starts penalising correct behaviour.**

A worked example. An assertion reads "did not treat video notes as textual
evidence", copied from a skill's "images and text only, ignore video". The
videos turn out to have subtitles, the policy flips — and the assertion
**stays in place, docking points for correct behaviour.** Both obvious rewrites
fail too: matching on the word "transcript" passes a sentence saying *the video
has no transcript*, **awarding points for asserting the opposite**; switching to
mechanism (field names, subtitle file extensions) then penalises "filter out
image posts at search time", which is a policy worth keeping.

⇒ **When you change a skill's policy, walk the assertions in the same pass.**
Assertions hold only what stays true regardless of policy (coverage is disclosed
honestly, numbers have provenance, nothing is fabricated). Policy preferences
(images-first vs video-first) do not go in assertions. **Read the evidence even
when an assertion passes** — the false pass above was visible only in evidence.

### Scheduling: both parallel and sequential runs contaminate

**Root cause: all scraping agents share one real browser session and one set of
sites, so they interfere with each other, and contaminated data looks exactly
like a genuine finding** — you cannot tell "the site changed" from "I throttled
myself". (This holds any time multiple scraping agents run at once, not only
during evaluation.)

- **Never run two versions of the same skill concurrently.** Hitting one site
  from both triggers throttling, which then gets misread as site behaviour.
- **Parallelism ≈ 3**, and prefer one agent per site.
- Give every agent a **fail-fast** instruction: stop after 2 consecutive
  network-layer failures, write up what you have, and say where you stopped.
  Without it, a local network outage leaves agents spinning for half an hour
  apiece and producing nothing.
- **On sites whose quota accrues per account, sequential runs contaminate too.**
  (This is where section 2's last row gets used.) A brand-new lane, the day's
  first item, thrown out on its first driving action because another agent
  exhausted the allowance hours earlier — and it looks like "this item never had
  content". Put quota-heavy tasks first or on separate days. **When reading
  results, check the log for the throttle code before deciding whether a number
  counts.**
- Each site's own throttling personality (how many requests trip a captcha, how
  quota accrues) goes in **that site's skill**, not here.

⇒ Before spawning, work out which site the agent will hit and whether it
collides with one already running. Afterwards, read call counts, not pass rates.

### The skill's "haven't tried" list is the run's work-list

An evaluation that only re-asks the old questions measures the skill's known
half. **Open the skill's "haven't tried" list first** (section 7) and put those
in the run — they are the entries that have been sitting unclaimed precisely
because nothing scheduled them, and every one that gets settled either becomes a
capability or moves to the "can't" list with a measurement behind it.

### Every evaluation ends in a file under `evals/`

An evaluation that only produces a verdict has thrown away the run. The call
counts, the questions, the assertion rewrites that failed, the findings judged
too thin to promote — all of it is what the *next* evaluation compares against,
and none of it can live in `SKILL.md`. Write it up per section 8 before drawing
the conclusion; the conclusion is one line at the top of that file.

## 10. Pre-commit checklist

**Run these three, they are not reading tasks:**

    grep -nE '[0-9]{4}-[0-9]{2}-[0-9]{2}' SKILL.md   # dates: must print nothing
    n=$(grep -c '^### ' SKILL.md); m=$(grep -c 'Self-check' SKILL.md)  # or this file's marker
    [ "$m" -ge "$n" ] || echo "$((n - m)) rule(s) with no self-check"
    node .../scripts/validate-metadata.mjs metadata.json    # and read the summary

**Then the rest:**

- [ ] Directory name and `name:` are both `passenger-<site>`
- [ ] It opens with a thesis sentence, not with rule 1
- [ ] Lookup or corpus was decided before the layout, and the layout matches
- [ ] Prior art was searched before probing — GitHub code search, userscripts,
      old wrappers — and the outcome, including "nothing found", is a line in
      `evals/`
- [ ] Every name taken from someone else's code was confirmed against the live
      site this session; no third-party repo is cited as authority in `SKILL.md`
- [ ] Every page type says whether it needs rendering
- [ ] Every hard rule is a silent failure — following it wrong yields a
      well-formed wrong answer. The rest moved to the capability table or the
      recipe
- [ ] No self-check relies on a length threshold; the threshold each one
      compares against is written into it
- [ ] Low-hit-rate fields state their consequence; shortfalls that are not
      failures say so
- [ ] No baseline section — the run's numbers are in `evals/`
- [ ] Every lookup table is in `metadata.json`, and `SKILL.md` states the flow
      without restating any row
- [ ] Every table has `on_mismatch` and `verify`; every unmeasured row is
      `verified: false`; `coverage` says whether a miss means anything
- [ ] A table the site publishes itself is `upstream` with a query, not a copy
- [ ] States what driving costs and how quota accrues
- [ ] Unrun recipes are marked, with a verification entry point
- [ ] Every recipe touched in this pass was actually run; body grepped for old
      field names and old API names
- [ ] Nothing restates or links to the tool itself or other generic capabilities
- [ ] **No other site is named anywhere** — not in `description`, not in the
      body. Boundaries are first-person; comparisons went to the family
      document. (Sole carve-out: a second route to *this same* site)
- [ ] `description` has no mechanism and is not a table of contents — only
      capability, when to use, and where this site's own boundary is
- [ ] "Won't", "can't" and "haven't tried" are three separate lists
- [ ] Every "cannot do / cannot reach" was verified in this pass, or it belongs
      in the "haven't tried" list instead
- [ ] Every "cannot reach" states **which login/permission state it was measured
      in**
- [ ] Login-using sites document how to log in, how to recover from risk
      control, and how to tell the session is still valid
- [ ] Delete every "previously / originally / now changed to" — do the sentences
      still stand?
- [ ] This run left a file in `evals/`, naming what it changed **and what it
      deliberately did not**
- [ ] Nothing new in `SKILL.md` is a single-run observation, unless it is a
      silent failure; the rest stayed in `evals/`
- [ ] `SKILL.md` does not link to `evals/`
- [ ] If evaluating: primary metric is call count / tokens, not pass rate; no
      assertion encodes a policy that can change
