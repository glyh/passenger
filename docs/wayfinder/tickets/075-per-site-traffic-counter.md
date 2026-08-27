---
id: 075
title: Counting what this side spent on a site
labels: [wayfinder:research]
status: open
assignee:
blocked_by: []
---

## Question


Rate limits are the failure mode this tool is least able to help with, and the
one it is best placed to measure. Three places already say so, all of them in
skills, none of them backed by a number:

- `using-passenger/SKILL.md`: *"That reputation is a shared budget. Sites meter
  per account, not per lane and not per session, so a brand-new lane on its
  first page of the day can be thrown out on its first click because something
  else spent the allowance hours earlier."*
- `references/tabs-and-lanes.md`: *"Agents working the same domain at once share
  everything that domain counts ... Keep concurrent work on one domain low, and
  prefer one agent per site."*
- `passenger-skill-authoring/SKILL.md`: *"you cannot tell 'the site changed'
  from 'I throttled myself'"*, and, on reading an evaluation, *"read call
  counts, not pass rates."*

Every one of those asks a caller to reason about a quantity — how much has been
spent on this domain, by everyone, since when — that no caller can see. The
agent knows what *it* did this session. It does not know what the lane next door
did an hour ago against the same account, and that is exactly the traffic that
gets it thrown out. "Keep concurrent work on one domain low" is advice a caller
cannot act on, because the thing it would have to look at does not exist. A
count is the one piece of this the tool holds and the caller does not.

So: **count per-origin traffic on this side, and let a caller read it back.**

### Why this is not [019](019-the-tool-does-not-learn.md)

The obvious objection is the standing rule: nothing durable about a *site* is
stored on this side. This proposal has to answer it before anything else, and
the answer is the same distinction the map already draws for lanes — *a lane is
bookkeeping, not memory*.

019 forbids the tool holding a **judgement about a site**: "this domain sits
behind DataDome", "comments here are behind a login". Those are conclusions,
made once from one page, that then act silently and forever, and they belong in
the agent's memory where a human can read and correct them.

A traffic count is not a conclusion about a site. It is a record of **what this
process did**, keyed by where it did it. It is the same species as lane
membership: it is about this side's own actions, the caller can read all of it
back, and nothing about it is a claim about the world. `github.com: 40 reads, 3
drives since 09:12` is not a fact about GitHub. It is a fact about us.

The three tests the map applies to lane membership are the ones to apply here,
and the third is the one this proposal may fail:

1. **It is about this side's own actions** — yes, by construction.
2. **The caller can read all of it back** — yes, if it ships with a read.
3. **It does not survive a Chrome restart** — *unresolved, and it is the
   decision.* A per-account allowance accrues over hours, which is longer than
   a Chrome process reliably lives. A counter that resets on restart answers
   "am I colliding with a lane right now" and says nothing about "was the
   day's allowance already spent". Those are two different tools with two
   different answers to 019, and picking one is most of this ticket.

### And it must not judge

`using-passenger` is built on *the tool measures; the caller judges*, and six
mechanisms have been deleted for crossing that line. A counter is a measurement
and stays one. What this must not grow into:

- A threshold — no "you are near the limit", no per-site budget, no refusal.
- A backoff, a delay, or a queue. The tool does not decide to wait.
- Anything per-site and fixed at build time about *how much is too much*. Each
  site's throttling personality goes in that site's own skill, and
  `passenger-skill-authoring` already says so.

The number goes out; the ruling stays with the caller. If that discipline
cannot hold, the honest outcome is to close this and leave the advice as advice.

## To decide

1. **What counts as one unit of traffic.** The skill already splits reading from
   driving — *"reading is invisible ... synthetic clicks and fills are not"* —
   and they cost wildly different amounts of the same budget. One number that
   adds them is close to meaningless. Candidates: navigations, `Page.request`
   calls, and driving actions, counted separately. Which of these can this side
   even see, given that a caller's script does its work inside `script` and this
   side never parses that source?
2. **What the key is.** Registrable domain, or origin? `docs.github.com` and
   `github.com` share an account and a limiter; `github.io` pages do not share
   with `github.com`. Getting this wrong makes the number worse than none.
3. **Where it lives, and for how long.** In-process beside `Lanes`, or on disk?
   This is test (3) above and the real 019 question. If on disk, what makes it
   bookkeeping rather than memory, and what removes it?
4. **How a caller reads it.** `browserStatus` already reports `wedged:` — a
   count per kind, read when calls have gone slow for no visible reason — and
   this is the same shape of answer to the same shape of question. Adding it
   there costs no new tool, which *One door onto a page* would otherwise make
   this argue for.
5. **Whether it is per-lane, cross-lane, or both.** Cross-lane is the whole
   point: the traffic that gets a caller thrown out is usually not its own. But
   a caller also needs its own number to know what it personally spent.
6. **What it does when Chrome was driven by a human.** A human browsing the same
   site in the same profile spends the same allowance and this side sees none of
   it. The count is a floor, never a total, and whatever reports it has to say
   so — a number a caller reads as complete is worse than no number.
