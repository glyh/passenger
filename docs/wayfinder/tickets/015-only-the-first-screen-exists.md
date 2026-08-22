---
id: 015
title: Only the first screen exists
labels: [wayfinder:research]
status: open
assignee:
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
