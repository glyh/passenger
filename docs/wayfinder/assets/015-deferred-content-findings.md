# Saying what a fetch did not reach

Measured 2026-08-23, logged-in session, one `script` call per batch. The
question is ticket 015's third point: the page says `共 177 条评论`, the
extraction holds 19, and nothing in the result reports either the
discrepancy or that scrolling exists.

Two candidate signals were measured against the same pages. They turn
out to be complementary, and neither one covers both of the cases the
ticket was written about.

## Signal A: scroll once and see whether the page grew

Scroll the document to the bottom, wait ~2s, re-measure `scrollHeight`,
node count and `body.innerText.length`. No content is collected -- this
is a probe, not the `scroll` parameter point 1 rejected.

    page                                   scrollH        textLen      nodes

    quotes.toscrape.com/scroll         1666 -> 3615   1492 -> 4683   109 -> 197
    xhs search_result (listing)        4171 -> 6302   2232 -> 2026  1323 -> 1184
    bbc.com/news                       7103 -> 7490  11334 -> 11708 4491 -> 4602
    en.wikipedia.org/wiki/Fog_of_war        unchanged in every column
    developer.mozilla.org (scrollHeight)    unchanged
    blog.rust-lang.org 1.81.0               unchanged
    news.ycombinator.com                    unchanged
    reuters.com/world                       unchanged, stable over 4s
    example.com                             unchanged

Four things follow.

**It works, and it is language-neutral.** The true infinite scroller
tripled its text; five static pages did not move a single byte.

**Text is the wrong column to watch.** On the xiaohongshu listing the
text and the node count went *down* while the document got 51% taller.
That is the recycling trap already recorded on the ticket, seen from the
other side: the result set appends, the rendered nodes are windowed, so
only `scrollHeight` tells the truth. A probe that watched text would
report *less* content after scrolling.

**There is a noise floor.** BBC grew 5.4% / 3.3% from lazy modules below
the fold with no new articles behind them. Anything under roughly 10%
is furniture.

**It does not reach the comments.** On note `6a881e24…` (`共 153 条评论`),
scrolling the *document* took `scrollHeight` 5377 -> 9045 while text
*fell* 3615 -> 3524: what loaded was the feed of other notes below, not
comments. The comments live in an inner scroller (`.note-scroller`,
`scrollHeight` 2994 against `clientHeight` 767). Scrolling that pane
instead moved text 3524 -> 4037 and nodes 2541 -> 2949.

So on the ticket's own motivating page, the document-level probe grows
for the wrong reason -- it would report "there is more" about content
the caller never asked for, which is worse than silence.

## Signal B: the page already said so, in text we already returned

The extraction of that same note contains, verbatim:

    共 153 条
    展开 23 条回复   展开 2 条回复   展开 4 条回复   展开 1 条回复   展开 7 条回复

Nothing new has to be read off the page. The markers are in the markdown
`fetch` already hands back, and the arithmetic is exact: at least
23+2+4+1+7 = 37 replies sit behind expanders nobody opened. That is a
lower bound derived from the page's own words, not an estimate.

Tested across languages, separating markers that carry a number from
bare ones:

    page                              numbered                     bare

    xhs note 6a881e24            共 153 条, 展开 23/2/4/1/7 条       --
    github rust-lang/rust#57893  "148 more comments"          "View all"
    news.ycombinator item 49397074  "1314 comments"           "see all", "older"
    old.reddit r/programming/top  2370, 1067, 1840, 1261, 329  "view more"
    xhs search_result (listing)       none                      none
    quotes.toscrape.com/scroll        none                      none
    en.wikipedia.org/wiki/Fog_of_war  none                      none
    developer.mozilla.org             none                      none
    blog.rust-lang.org                none                    "load more" x1
    bbc.com/news                      none                    "load more" x2
    example.com                       none                      none

**Numbered markers had zero false positives** on six negative controls.
**Bare ones did not**: "load more" / "view all" fired on the Rust release
blog and on BBC, where they are navigation furniture. Bare markers are
noise; numbered ones are signal.

**A bare count is not a claim about this page.** The old.reddit listing
matched five numbers against `\d+ comments` -- every one of them the
comment count of a *listed post*, none of them a statement that this page
had more. So "N comments" only means something next to an affordance that
says content is being withheld; `展开 N 条回复` and `148 more comments`
are self-evidently about deferral, `1314 comments` is not.

**It is blind where the page defers silently.** The xiaohongshu listing --
22 -> 619 notes, half this ticket's evidence -- carries no numbered marker
and no bare one. Its markdown simply ends `回到顶部 / 加载中`. So does
`quotes.toscrape.com/scroll`: it defers everything and says nothing.

## The two signals are each other's blind spot

    case                          signal A (probe)      signal B (markers)

    xhs note, 153 comments        wrong reason          exact: >= 37 hidden
    xhs listing, 22 -> 619        +51% scrollH          nothing
    quotes.toscrape/scroll        +214% text            nothing
    github issue, 148 hidden      untested              exact: 148
    six static negatives          clean                 clean

## What each costs

Signal B is a pure function of a string this project already produced.
No page access, no latency, no interaction, and it can be tested against
fixture text with no browser -- which is where this codebase puts things
it wants to keep honest. Its failure mode is silence, which is exactly
today's behaviour, so it can only improve the answer. Its cost is a
string table that will always be incomplete.

Signal A costs a synthetic scroll on every fetch. That is not a latency
argument (2-4s), it is a change of kind: ticket 004 measured that reading
a page is free and invisible, and driving one spends the reputation of a
session whose whole value is that it has never done anything unusual.
Making every read a drive spends that continuously, on every page,
including the overwhelming majority that have nothing deferred. And to
cover the comments case at all it would have to scroll inner containers
too, which multiplies the interaction rather than bounding it.

## Also observed

The Hacker News thread with 1,313 comments returned **462,337 characters**
of markdown from a single `fetch`. That is the map's standing "a fetch
returns the whole page and nothing bounds it" with a number attached.
