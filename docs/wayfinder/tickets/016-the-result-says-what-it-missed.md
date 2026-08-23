---
id: 016
title: The result says what it did not reach
labels: [wayfinder:task]
status: open
assignee:
blocked_by: []
---

## Question

[Only the first screen exists](015-only-the-first-screen-exists.md)
decided the signal and measured it; this is the building of it.

A page that says `共 153 条评论` and hands over 19 of them currently
returns those 19 with no hedge at all. The markers that say so are
already in the markdown the extraction produced -- `共 153 条`, five
`展开 N 条回复` -- and nothing reads them.

So: a pure function over `Extraction.text`, and a field on `Fetched` to
carry what it found. Because both doors build `Fetched` through
`service._fetched`, `fetch` and `script`'s ending-page read get it in
the same change.

The measurements that constrain it are in [Saying what a fetch did not
reach](../assets/015-deferred-content-findings.md):

- Only markers carrying a **number** are admissible. Numbered markers had
  zero false positives across six negative controls; bare "load more" and
  "view all" fired on the Rust release blog and on BBC, where they are
  navigation furniture.
- A bare total is not a claim about the page. `\d+ comments` matched five
  times on a reddit listing, every one a listed post's own count. A total
  is admissible only alongside an affordance that says content is
  withheld.
- The numbers add up to something exact. 23+2+4+1+7 means at least 37
  replies are behind expanders, which is arithmetic on the page's own
  words rather than an estimate.

To decide while building:

1. The shape of the field. Quoting the markers found plus their sum is
   the conservative reading of 015 -- evidence rather than a verdict, so
   the caller judges. A bare boolean invites the opposite mistake to the
   one being fixed: `deferred: false` on a page that defers silently is a
   confident wrong answer, where an absent list is merely quiet.
2. Whether the hint names `script`. 013 shipped the cure; a caller who
   does not already know to reach for it is exactly the caller this
   ticket exists for.
3. Where the string table lives, and how a locale is added to it without
   touching the logic. It starts CJK plus English because that is what
   was measured; it will always be incomplete, and that has to be cheap
   rather than embarrassing.
4. Whether `word_count` should be joined by the count of markers, or
   whether the list standing alone is enough.
