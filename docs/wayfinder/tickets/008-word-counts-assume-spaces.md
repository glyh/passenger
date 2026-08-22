---
id: 008
title: Word counts assume spaces, so CJK pages read as empty
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
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

## Answer

Real segmentation, not a heuristic. `ab/text.py` holds one `count_words`,
and both consumers -- `Extraction.word_count` and `choose` -- now call it.

The ticket's own point 1 proposed counting CJK codepoints as words, and
point 4 asked whether `min_words = 80` would still mean anything. Both are
moot: ICU's `BreakIterator` does dictionary-based segmentation, so the unit
stays "word" in every script and the threshold keeps its meaning unchanged.
That closes point 2 as well -- there is no reason to restate `min_words` in
characters, so the public MCP parameter does not change and no caller
breaks. Point 3 (whether `classify` and `choose` want different measures)
resolves to no: once both inputs are counted honestly, one ruler serves the
threshold and the ratio alike.

PyICU is a real native dependency and was weighed as one. jieba covers
Chinese only and would leave the Thai case in [Reaching content that sits
behind an interaction](004-driving-the-page.md) still broken; uniseg
implements UAX #29, which without a dictionary counts each Han ideograph as
a word and leaves Thai runs whole -- the rejected heuristic, with a
dependency attached. ICU is the only one that covers every unspaced script,
and nixpkgs ships it prebuilt.

Measured:

| text | `len(split())` | `count_words` |
|---|---|---|
| zh.wikipedia 珠海市, live through `article` | 2,196 | 22,014 |
| note body, 1,890 Chinese characters | 1 | 1,050 |
| search listing, 1,240 characters | 1 | 520 |
| ICP footer, 44 characters | 4 | 17 |
| `hello world foo` | 3 | 3 |

Both halves the ticket describes are fixed by the one change. `classify`
no longer calls a rendered CJK page blocked, so the `^<query> - 小红书搜索`
proposal cannot arise by this route. And `choose` now compares 17 against
520 rather than 4 against 1, so the yield floor trips and `auto` returns the
listing instead of the footer -- the reason the xiaohongshu recipe had to
pin `mode` per page type.

Note what this does *not* fix. A thin page is still called blocked on a low
count alone, which is [The extract mode decides whether a page counts as
blocked](005-mode-decides-blocked.md); `example.com` measures 30-odd words
in any unit and still proposes `^Example\ Domain` as a signature. Counting
honestly removes the false readings, not the weak rule that consumes them.

Regression seams landed with it, as the ticket asked: `tests/test_text.py`,
`tests/test_extract.py` and `tests/test_detect.py`, all pure, no browser,
with the CJK fixtures sized to the measurements above. They run under
`pytest` in the dev shell. This is a narrower thing than [What the test
suite covers, and how the shells get tested](001-testing-the-shells.md)
wants and does not pre-empt it -- only the pure core is covered.
