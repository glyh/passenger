---
id: 008
title: Word counts assume spaces, so CJK pages read as empty
labels: [wayfinder:task]
status: open
assignee:
blocked_by: []
---

## Question

`Extraction.word_count` is `len(text.split())`. Chinese, Japanese and
Thai do not put spaces between words, so a whole paragraph counts as one
or two "words". Every decision downstream of that number is therefore
wrong on a CJK page, in the direction of believing the page is empty.

Measured on xiaohongshu, all fully rendered and logged in:

    search_result  mode=dom      ~40 result cards          66 words
    search_result  mode=article  the ICP footer, no more   60 words
    explore/<id>   mode=dom      full note + 13 comments  172 words
    explore/<id>   mode=article  full note + 13 comments  105 words

The note body alone is about 1,800 Chinese characters. It counts as 172.

Two consequences, both observed rather than reasoned:

**The classifier calls a live page blocked.** `min_words` defaults to 80.
The search page renders forty results and counts 66, so `classify`
returns a `NovelBlocker` on a page with nothing whatsoever in the way.
`propose_signature` then fell through to the title branch and offered:

    ^珠海长隆海洋王国\ \-\ 小红书搜索

which is `<query> - 小红书搜索` -- not even site-wide, but specific to
one search phrase, so approving it would blocklist a single query
string. That is the unsoundness described in [The extract mode decides
whether a page counts as blocked](005-mode-decides-blocked.md), reached
by a different road: 005 gets there because `article` legitimately finds
nothing in a JS app, this gets there because the ruler is metric and the
page is imperial. Fixing 005 alone leaves this live -- `auto` is 005's
immunity, and `auto` is broken here too, which is the next point.

**`choose` picks the empty extraction.** On the search page, article
yields 60 and dom 66. `_MIN_COMPARABLE_WORDS` is 40, so the comparison
runs; `_ARTICLE_YIELD_FLOOR` asks whether 60 < 0.35 x 66, which it is
not, so `auto` returns article. Article, on that page, is the ICP
footer. Both numbers are noise, and the floor between them compared
noise to noise and discarded the entire result set. This is why the
xiaohongshu recipe has to pin `mode` explicitly per page type -- `dom`
for listings, `article` for note bodies -- rather than trusting `auto`.

To decide:

1. What the unit should be. Counting CJK codepoints as words each -- so
   `len(re.findall(r'[一-鿿぀-ヿ가-힯]', t)) +
   len(t.split())` -- is a few lines and no dependency, and is roughly
   right: Chinese averages under two characters per word, so it
   over-counts by a factor near two rather than under-counting by fifty.
   Proper segmentation (jieba, ICU) is a real dependency for a threshold
   that only ever needs an order of magnitude.
2. Whether to count characters throughout instead, and restate
   `min_words` in characters. Honest for every script, but it is a
   public MCP parameter and a breaking change to what callers pass.
3. Whether the two uses want the same measure at all. `classify` asks
   "is there anything here", `choose` asks "did one extractor keep more
   than the other" -- a ratio, which survives a biased unit as long as
   the bias is the same on both sides. It is not the ratio that failed
   above so much as both inputs being floored near zero.
4. Whether `min_words`'s default of 80 still means anything once the
   unit changes.

Both halves are pure and need no browser to test: `classify` against a
fixture `PageProbe`, `choose` against two fixture strings. A CJK string
belongs in whatever fixtures [What the test suite covers, and how the
shells get tested](001-testing-the-shells.md) lands with.
