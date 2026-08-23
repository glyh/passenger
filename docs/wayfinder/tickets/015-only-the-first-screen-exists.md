---
id: 015
title: Only the first screen exists
labels: [wayfinder:research]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

`fetch` is `goto`, settle, read. Whatever a page defers until the reader
scrolls is therefore never in the result -- and, unlike a challenge, it
leaves no trace that says so. The page looks complete because it *is*
complete, for a reader who never moved.

Measured on xiaohongshu, logged in, both modes:

    /explore/6a6b90be…   header says   共 177 条评论
                         reachable     12 top-level + ~7 inline replies
                         collapsed     10 "展开 N 条回复" markers, 105 replies

    /explore/6a01c765…   header says   共 36 条评论
                         reachable     10

So 11% of one comment section and 28% of the other, with the page's own
count sitting right there in the text to contradict it. The listing case
is the same defect: a search result page renders 20-40 cards and no URL
parameter pages it (`page=2`, `sort=`, `note_type=` are all front-end
click state and are ignored), so the first screen is not the first page
of results, it is all of them.

This matters more than a truncation usually would, because of *which*
content is deferred. The vault's xiaohongshu method rates the comment
section above the note body -- a local resident contradicting a
travel-blogger's claim is the highest-value thing on the page, and it is
exactly what sits under "展开 23 条回复". The reachable prefix is
systematically the *least* informative slice: top-level comments ordered
by engagement, which is where the bland agreement and the paid-promotion
replies live. An agent reading 11% and reporting "the comments broadly
agree" is not making a small error.

[Reaching content that sits behind an interaction](004-driving-the-page.md)
decided the general answer -- caller-supplied script with `page` bound,
built in [The passthrough tool that runs a script against a
page](013-the-passthrough-tool.md), blocked on [One wedged tab bricks
every later call](012-one-wedged-tab-bricks-every-call.md). This ticket
is not asking to duplicate that. It is asking whether the *common* case
deserves to be reachable without it, because scrolling to the bottom
until nothing more loads is not a bespoke interaction, it is what reading
a page means on a site built after 2010, and every caller who needs it
would otherwise write the same three lines of Playwright.

To decide:

1. Whether a `scroll` parameter on `fetch` earns its place, or whether
   waiting for 013 is right and this ticket is only here to record the
   size of the gap. A bounded "scroll until the document stops growing,
   at most N passes" is a small surface; it is also a second way to do
   something 013 will do generally, and two ways is the thing this
   codebase keeps avoiding.
2. What it does to output size. This multiplies the problem already in
   the map's Fog -- a fetch returns the whole page and nothing bounds it.
   177 comments is perhaps 8x what 19 comments cost. Scrolling and
   capping probably have to arrive together, and a cap that truncates
   silently would reintroduce this ticket one layer up.
3. Whether the result should say what it did not reach. This is the
   cheapest half and possibly the most valuable: the page states `共 177
   条评论`, the extraction contains 19, and the arithmetic is available
   without any new capability. A `truncated` or `deferred_content` signal
   -- even a heuristic one -- turns a silent wrong answer into a hedged
   right one. Generalising past the CJK-specific "共 N 条" string is the
   real question.
4. Whether "展开 N 条回复" is reachable by scrolling at all, or whether
   each is its own click and therefore genuinely 013's problem. The two
   are different mechanisms wearing the same disguise, and the numbers
   above conflate them: of the 158 comments not reached on that note, 105
   are behind expanders and the rest are below the fold.

## Update, after 013 landed

`script` closes the capability gap, measured on the same two pages:

    comments   scroll + click .show-more    177/177, 9 rounds
    listing    scrollBy(innerHeight*0.9)    22 -> 619 unique notes, 6 rounds

So point 1 is answered by "013 was enough" -- no `scroll` parameter on
`fetch` is needed for these. Two findings worth keeping:

- The listing **appends**; it does not virtualise. An early read of
  `.note-item` count suggested recycling (the number hovered near 30 and
  fell as well as rose), which is what a caller will conclude if they
  count nodes instead of accumulating identity. Collect ids into a set.
- Each result card carries *two* anchors: the title link with
  `?xsec_token=…` and a bare `/explore/<id>` cover link. The bare one
  silently redirects to the caller's own feed. A naive "collect every
  note href" gets a set that is half traps.

Point 3 is the part 013 did *not* answer and this ticket should be kept
open for: nothing in a `fetch` result says the page held more. The page
states `共 177 条评论`, the extraction contains 19, and the tool reports
neither the discrepancy nor that scrolling exists. A caller who does not
already know to reach for `script` still gets a confident 11% answer.

## Answer

Yes -- and by quoting the page's own words back, not by looking again.

Measurements in [Saying what a fetch did not
reach](../assets/015-deferred-content-findings.md), across eleven pages
in three languages.

The finding that decides it: **the evidence is already inside the
markdown `fetch` returns.** The extraction of a note claiming `共 153
条评论` contains that string and all five of its `展开 N 条回复` markers.
Nothing has to be read off the page, because it was read off the page
already and thrown past unexamined. Summing the numbers those markers
carry gives an exact lower bound -- at least 37 replies withheld -- from
the page's own arithmetic rather than an estimate.

So the signal is a **pure function over the extracted text**, and it
lands on `Fetched` where both doors already build it. It reports what it
found rather than a verdict: the markers, and the count they add up to.
Two rules come out of the measurements:

- **Only markers that carry a number count.** Numbered markers had zero
  false positives across six negative controls; bare "load more" /
  "view all" fired on the Rust release blog and on BBC, where they are
  furniture.
- **A bare total is not a claim about this page.** `\d+ comments` matched
  five times on a reddit listing, every one of them a listed post's own
  count. A total means something only beside an affordance that says
  content is being withheld.

Its failure mode is silence, which is today's behaviour, so it can only
improve the answer; its cost is a string table that will never be
complete.

### What was rejected, and why

Scrolling once and checking whether the page grew. It works -- the true
infinite scroller tripled its text while five static pages did not move a
byte -- and it covers precisely the case the marker signal misses. It was
rejected as a default for two reasons.

It answers the wrong question on this ticket's own page: scrolling the
document of a note grows it 5377 -> 9045 while the text *falls*, because
what loads is the feed of other notes below, not the comments. The
comments are in an inner scroller. A probe that reported "there is more"
there would be confidently pointing at content nobody asked for.

And it changes what a read *is*. Ticket 004 measured that reading a page
is free and invisible while driving one spends the reputation of a
session whose whole value is that it has never done anything unusual.
A growth probe makes every fetch a driving act, continuously, on the
overwhelming majority of pages that have nothing deferred -- and to reach
the comments it would have to drive inner containers too.

### What stays unreached

Pages that defer silently. The xiaohongshu listing -- 22 -> 619 notes,
half the evidence in this ticket -- carries no numbered marker and no bare
one; its markdown ends `回到顶部 / 加载中`. `quotes.toscrape.com/scroll`
says nothing either. For those, `script` remains the whole answer, and
the tool stays quiet rather than guessing. That gap is now named in the
map's Fog instead of being invisible.

Not built. [The result says what it did not
reach](016-the-result-says-what-it-missed.md) took this answer one step
further and it does not survive the step: if the markers are already in
the markdown the caller holds, then reading them is the caller's job, and
a per-language regex table is a worse recognizer than the agent it would
be serving. What stands is the measurement -- and the guidance, which now
lives with the agent rather than in this layer.
