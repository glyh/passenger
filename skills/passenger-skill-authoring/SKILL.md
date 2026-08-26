---
name: passenger-skill-authoring
description: |
  Use when writing a scraping skill for a specific website, revising one, or
  evaluating whether an existing one earns its keep. Trigger phrases: "write a
  skill for <site>", "we keep re-learning this site", "this site's skill did not
  help", "is this skill worth keeping", "A/B two versions of a scraping skill".
  Covers what to probe for, which findings to record, how to phrase them, where
  a run's evidence is logged, and how to measure whether the skill helped.
  Does NOT cover performing a single scrape, and does NOT cover any individual
  site's mechanics — those belong in that site's own skill. For driving the
  browser at all, use `using-passenger` instead.
---

# Writing a scraping skill for a site

**This document's most common failure is not a missing rule. It is a rule that
was not recalled at writing time.** Two measured violations — mechanism leaking
into `description`, and body text written as revision history ("the previous
record has been overturned") — map to one rule that was already written and one
that should have been. The author had read this document both times.

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
3. **When not to use it / who owns that instead** (negative routing, e.g. "this
   skill cannot reach that page type; use another source")

**Mechanism never goes in `description`:** selectors, field names, URL shapes,
evidence for silent failures. All of it stays in the body, which is in front of
the reader the moment the skill loads. Duplicating it means maintaining two
copies; edit the body, forget the description, and you have a lie that raises no
error and that nobody discovers until the description and the measured body
contradict each other in front of a user.

**Test after writing a description:** does this sentence help me *choose* this
skill, or help me *use* it? If the latter, move it into the body.

Every section below asks the same question: **what did you hit this time that
the next person will hit identically?** Things that are hit *and recognised*
(errors, 404s, timeouts) need no entry. **Things that are hit and not
recognised** are what to write down.

Write only what is true of that site. How the tool itself works, and generic
scripting traps, are not here — and **must not be restated or linked to from the
produced skill**. They have their own owners, and both copies and pointers rot.

---

## 1. Probe for the cheapest read first — it is half the skill's value

Taking a site from "render plus 25 scroll rounds" down to "fetch the HTML once"
justifies the whole skill on its own. It is also a cost **only the first prober
pays**: everyone after either follows the recipe or re-derives it.

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

## 3. Record baseline numbers

Baselines have exactly one use: **letting the next run decide whether it is
abnormal.**

> 12 scroll rounds ≈ 35s for 37 items; 1–5 live units per round; 36/37 have a
> date; **only 12/37 have a permalink**; 33/37 have body text (the rest are
> image-only posts, which is not a failure).

⚠️ **Call out any field with a low hit rate and state the consequence.** The
12/37 above means **the dedup key must have a degraded branch**, or the same
item is counted repeatedly or the batch is dropped.

**`SKILL.md` carries one baseline — the current one.** Superseding it does not
mean the old one was worthless: it is what "abnormal" was judged against, so the
previous run's numbers stay in that run's file under `evals/` (section 8), and
`SKILL.md` never accumulates two.

⚠️ **State explicitly which shortfalls are not failures** (image-only posts
never had text), or the next person will fix something that is not broken.

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
- **Whether logging in trips risk control, and how to recover.** Measured: one
  site flagged the account and restricted web access on merely *opening the
  login page*, and a retry the next day succeeded. ⇒ Write it as an executable
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

Measured: an audit of the tool's own skill turned up four such statements — a
warning that return values carry an extra `$id` field, three API names in the
previous runtime's spelling (`Page.APIRequest`, now `Page.request`), and a
closing code block still written in the previous language. Each was correct when
written. All failed silently: following them returns `undefined`, and
`undefined` at that line looks exactly like "this page does not have that".

⇒ **Every assertion about *how the tool behaves* must state what it was measured
against** — not just login state (section 4) but the tool's or site's version or
shape at the time.
⇒ **When revising a skill, actually run every recipe you touch.** Far more
effective than re-reading. All four findings above came from running; many
read-throughs had missed them.
⇒ A cheap self-check: **grep the body for spellings that should no longer
exist** (old field names, old API names, the previous language's syntax). Faster
than re-reading, and it targets this class specifically.

## 7. Committing the file

### Style: describe the site as it is now, not what you changed

A skill is **a description of the current state, for the next person.** It is
not a revision log for you. Revising an existing skill is where changelog voice
creeps in. Measured forms it takes:

- "the previously recorded 'these two page types are unreachable' **has been
  overturned**"
- "**first attempted 2026-08-24**, restricted; **retried 8-25**, succeeded"
- "originally we worried this needed a 'measured on one category only' caveat;
  **it can now** be treated as a general structure"

The reader does not know what "previously" was and does not care which day it
changed. They want to know **what the site looks like now.** Rewrite every
sentence as a property of the site: *logging in trips risk control; if it does,
retry the next day.* One sentence, no timeline, executable.

**Dates survive in exactly one place**: the provenance of baseline numbers
("measured 2026-08-25, Beijing, N=2"). That is a statement of measurement
currency, not a change record — the reader uses it to judge whether the numbers
have expired.

**Test: delete every date and every "previously / originally / now changed to".
Do the sentences still stand?** If not, it was a changelog.

**Deleted, not lost.** What comes out here is the run's evidence, and it is
worth keeping — in `evals/`, which is section 8. "Overturned", "first attempted,
then retried", "we used to worry about" are all correct sentences *there*.

### File layout

**`SKILL.md`:**

- **Hard rules** — silent failures, one per section, **each with its own
  self-check**. This is the part read first.
- **Capability table** — which page types need rendering, which come back in one
  fetch; what this site does and does not yield.
- **Method** — the "where the good material is" content from section 5.
- **Out of scope** — explicit boundaries, especially when using the user's login.
- **Reporting requirements** — what a conclusion must disclose (coverage, dates,
  provenance of numbers).

**`references/`:** one file **per page type** (listing, detail, comments…),
plus one file for **this site's own** scripting traps. Nothing generic.

**`evals/`:** one file per run — the datapoints behind everything above, and the
only place a date or a "this used to be true" belongs. Section 8.

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
2. **Numbers, per question.** Calls, tokens, failed calls, wall clock — section
   9's primary metrics. This is the row a later run compares against; without a
   recorded baseline, "it got faster" is a feeling.
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
past round 12 adds nothing." These are never sentences `SKILL.md` should carry —
it says what to do, not the list of things that do not work — but re-checking
each of them costs a probe. The log is where a probe gets paid for once.

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

In one A/B across 7 skills, **63 pass/fail assertions came out identical on both
sides in six of the pairings** — almost no discriminating power. The reason is
that the model routes around stale descriptions on its own: it discovered
unaided that the timetable could not be read with `fetch`, that air quality fell
back to the parent state, and that listing-price percentages dropped their sign.

What does discriminate is **call count and tokens**: one skill, once fixed, went
from 11–12 calls / 238–290s down to 5–6 calls / 100–108s, because the agent no
longer had to rediscover the silent failure.

⇒ **Primary metrics: call count, tokens, failed-call count.** Assertions are a
backstop for hard errors only.

A skill's value is not "makes the answer correct" — the model can usually
recover on its own. It is "nobody has to step in the same hole again". **Scoring
on correctness produces the wrong conclusion — "this skill is useless" — and
then deletes the very holes most worth recording.**

Two adjacent traps:

- **Assertions themselves frequently have bugs.** Read the evidence before
  flagging: in one evaluation, 4 assertions flagged behaviour that was correct.
- **Do not use test questions whose answers are already written in the skill
  body.** Re-test with an example the skill never mentions before it counts.

### Assertions weld old policy into the evaluation

Distinct from "assertions have bugs" and worth its own entry: **an assertion
freezes the skill's policy at the time it was written, and once that policy is
overturned it starts penalising correct behaviour.**

Example: an assertion read "did not treat video notes as textual evidence",
copied from the skill's then-current "images and text only, ignore video". Later
measurement found the videos have subtitles and the policy changed — and the
assertion **stayed in place, docking points for correct behaviour.** Two rewrites
failed in turn: matching on the word "transcript" passed a sentence saying *the
video has no transcript* (**awarding points for asserting the opposite**), and
switching to mechanism (field names, subtitle file extensions) then penalised
"filter out image posts at search time" — which review had confirmed as the
policy to keep.

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
  Measured: 3 agents spun for 28–32 minutes during a local network outage and
  produced nothing.
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

### Every evaluation ends in a file under `evals/`

An evaluation that only produces a verdict has thrown away the run. The call
counts, the questions, the assertion rewrites that failed, the findings judged
too thin to promote — all of it is what the *next* evaluation compares against,
and none of it can live in `SKILL.md`. Write it up per section 8 before drawing
the conclusion; the conclusion is one line at the top of that file.

## 10. Pre-commit checklist

- [ ] Directory name and `name:` are both `passenger-<site>`
- [ ] Every page type says whether it needs rendering
- [ ] Every silent failure has a self-check, and no self-check relies on a
      length threshold
- [ ] Baseline numbers call out low-hit-rate fields and their consequences
- [ ] States what driving costs and how quota accrues
- [ ] Unrun recipes are marked, with a verification entry point
- [ ] Every recipe touched in this pass was actually run; body grepped for old
      field names and old API names
- [ ] Nothing restates or links to the tool itself or other generic capabilities
- [ ] `description` has no mechanism and is not a table of contents — only
      capability, when to use, and who owns it otherwise
- [ ] Every "cannot do / cannot reach" was either verified in this pass or says
      verbatim that it was not tried
- [ ] Every "cannot reach" states **which login/permission state it was measured
      in**
- [ ] Login-using sites document how to log in, how to recover from risk
      control, and how to tell the session is still valid
- [ ] Delete every date and every "previously / originally / now changed to" —
      do the sentences still stand? (Sole exception: provenance of baseline
      numbers)
- [ ] This run left a file in `evals/`, naming what it changed **and what it
      deliberately did not**
- [ ] Nothing new in `SKILL.md` is a single-run observation, unless it is a
      silent failure; the rest stayed in `evals/`
- [ ] `SKILL.md` does not link to `evals/`
- [ ] If evaluating: primary metric is call count / tokens, not pass rate; no
      assertion encodes a policy that can change
