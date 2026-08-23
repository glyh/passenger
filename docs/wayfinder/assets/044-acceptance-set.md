# The acceptance set, with URLs

Asset for [Whether article's last job can be done
structurally](../tickets/044-articles-last-job-structurally.md), decision 5.

[025](../tickets/025-whether-dom-alone-is-enough.md) named its five pages by
site and character count and recorded **no URL for any of them**, in the ticket
or the assets, so the set it measured cannot be re-run. These are replacements,
found and verified 2026-08-24: same sites, same *shapes*, different articles.
Every one was checked to still carry the diagnostic 025 relied on, because a
page from the right site with the wrong shape tests nothing.

Character counts are `document.body.innerText` at fetch time and will drift.
The **diagnostic** is the part that has to survive; if it stops holding, the
page needs replacing again and this file is where that gets recorded.

| site | URL | body | diagnostic (verified) |
|---|---|---|---|
| chinadaily (en) | `https://www.chinadaily.com.cn/a/202608/21/WS6a87a60aa3106bc57421cac1.html` | 2,482 | **10 pagination links** — `…cac1_2.html`, `_3`, `_4` … The multi-page marker `article` deletes and `dom` keeps ([015](../tickets/015-only-the-first-screen-exists.md)). |
| chinanews (zh) | `https://www.chinanews.com.cn/gn/2026/08-23/10682776.shtml` | 1,741 | A related-news rail as the page's largest repeated run (4 siblings, 4,234 chars) — the labels `article` drops. |
| gmw (zh) | `https://news.gmw.cn/2026-08/23/content_38958102.htm` | 4,060 | **`div.g-wxTips`, hidden, with text**: 点击右上角微信好友 朋友圈… The WeChat share overlay trafilatura includes as body text and `checkVisibility()` filters. |
| americanthinker (en) | `https://www.americanthinker.com/articles/2026/08/the-tyranny-of-voter-apathy/` | 15,599 | **30 `<article>` elements**, exactly the count 025 recorded — the decoy-root case ([028](../tickets/028-the-root-heuristic-picks-a-decoy.md)). Largest repeated run: 263 siblings, 23,407 chars. |
| moonofalabama (en) | `https://www.moonofalabama.org/2026/08/war-on-iran-irans-advantage.html` | 61,687 | **100 comment siblings holding 55,745 chars** beside a 5,572-char post that is the one uniquely shaped child. The case this whole ticket is about. |

## Notes for whoever runs it

- **These are not 025's pages.** Its numbers (`article` 1,639 / `dom` 5,521 on
  chinadaily, and so on) belong to articles that were current in early 2026 and
  are not recoverable. Do not compare new measurements against that table
  expecting them to line up; compare *behaviours*.
- **One false positive to ignore.** The probe counts gmw's `node_*.htm` nav
  links as pagination (137 of them). Real pagination on that site looks like
  chinadaily's `_2` suffix. The gmw page is in the set for its hidden overlay,
  not for pagination.
- **americanthinker's 263-sibling run is not comments.** It is the teaser grid,
  and it is the reason that page doubles as a test of decision 1: a run that a
  caller must be able to see listed and choose *not* to drop.
