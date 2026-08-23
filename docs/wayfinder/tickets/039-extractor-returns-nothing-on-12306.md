---
id: 039
title: The dom extractor returns nothing where inner_text returns a page
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

On 12306's ticket-results page, `dom` extracts **zero characters** from a page
that has loaded and is sitting there readable. Same call, same tab, same
moment:

    page.inner_text("body")  ->  2647 chars, including 共计22个车次 and the table
    read(page)               ->  0 chars

`fetch` reports this as an ordinary success: `type='fetched'`,
`char_count: 0`, `markdown: ""`, `title: "中国铁路12306网站"`. No `blocked`, no
error. Settle times of 14s, 20s and 25s make no difference, which rules out
the obvious reading that the page had not finished rendering.

    https://kyfw.12306.cn/otn/leftTicket/init?linktypeid=dc&fs=玉溪,AXM&ts=西双版纳,ENM&date=2026-08-26&flag=N,N,Y

`article` on the same URL is the more interesting half. It returns 2381
characters of **table skeleton** -- 22 rows, which is exactly the 22 trains
that are really there -- with the 余票 columns and every `预订` link intact,
and 车次 / 出发站 / 到达站 / 出发时间 / 到达时间 / 历时 **all empty**. A caller
gets a plausible-looking table and not one train number. That is worse than
the zero: zero is at least legible as failure.

Found from the outside, by two agents in a Notes-vault eval that were reading
the `railway-12306` skill. Both concluded the skill's `fetch` path was broken
and fell back to `script` unaided; the skill now documents `inner_text` as the
only way to read this page. So the caller-side workaround exists and this
ticket is not blocking anyone -- what it is, is a hole in the story this
codebase tells about itself.

**Why it matters here rather than in the vault.** The standing division is
[the tool measures, the skill holds what to look
for](038-a-fetched-that-says-this-reads-like-a-wall.md), and `char_count` is
the number a caller is handed to judge completeness by. A `char_count` of 0 on
a page that visibly has 2647 characters of text is not a measurement of the
page; it is a measurement of the extractor. [The result says what it did not
reach](016-the-result-says-what-it-missed.md) built the shape for reporting
withheld content, and this is content withheld by *this side* without saying
so.

To decide:

1. **What the extractors actually choke on.** 12306 renders the results table
   through its own templating into a structure the readability pass and the
   dom walk both discard. Whether this is one site's markup or a class --
   JS-populated tables generally -- is unknown, and one instance is not a
   class. The cheap probe is a handful of other JS-table pages before anything
   is changed.
2. **Whether a zero-character extraction should be sayable.** `Fetched` can
   already carry that the page rendered pictures the markdown cannot hold
   (017). An extraction that came back empty from a page whose DOM has text is
   the same kind of admission, and unlike 038's wall phrases it needs no
   phrase table and no language list: it is a comparison of two numbers this
   side already has. The trap is that it must key on *the extractor found
   nothing while the document had something*, never on "short", which is the
   floor 005 and 011 each deleted.
3. **Whether `inner_text` belongs in `script`'s scope at all.** It is reachable
   today only because `page` is a real Playwright handle. If it is the
   documented escape hatch for pages the extractors cannot read, that is worth
   one line in `script`'s docstring; if it is not, callers are relying on an
   accident.
4. **Nothing here argues for a fallback.** An extractor that silently switched
   to `inner_text` on an empty result would be `auto` again
   ([021](021-remove-auto-mode.md)) wearing a different hat -- guessing on the
   caller's behalf, and hiding the very signal this ticket is about.

## Answer

**Closed undone.** Nothing was investigated and nothing was built: the probe in
decision 1 was never run, so whether this is one site's markup or a class of
JS-populated tables is still unknown. This records a disposition, not a finding.

The case for closing is that the caller-side story is already complete. The
`railway-12306` skill in the Notes vault documents all three behaviours -- `dom`
at 0 characters, `article`'s skeleton, `inner_text` as the way through -- and
routes every caller down the working path before they can hit the broken one. Two
agents found that path unaided, which is the evidence that the failure is legible
from outside even though this side does not name it. Nobody is blocked, and the
one page known to be affected is handled.

What stays wrong is unchanged and worth saying plainly, because closing a ticket
is not the same as the problem going away: `char_count: 0` on a page whose DOM
holds 2647 characters is this side reporting on its own extractor while appearing
to report on the page, and `article`'s 22 rows with every identifying column empty
is worse than the zero, because it looks like a result. A caller who has not read
the vault skill has no way to tell either from a genuinely empty page.

Two things were learned from the skill rather than from a probe, and are recorded
here so a later session does not re-derive them:

1. **Which cells survive `article`.** 余票 and 预订 come through; 车次, 出发站,
   到达站, 出发时间, 到达时间 and 历时 do not. The surviving cells are static
   markup and the dead ones are template-filled, which is a hypothesis about the
   seam -- and a prediction the probe could test, if other JS-table pages fail
   along the same line.
2. **`inner_text` has a production caller.** Decision 3 asked whether callers
   relying on it are relying on an accident. They are relying on it deliberately,
   on this skill's instruction. That question is answered even though the ticket
   is not: the escape hatch is load-bearing, and if `script`'s scope is ever
   narrowed, this is what breaks.

Decision 4 stands untouched and should stay that way whenever this is reopened: no
fallback. An extractor that silently switched to `inner_text` on an empty result
is [`auto`](021-remove-auto-mode.md) wearing a different hat.

**What would reopen it:** a second page that fails the same way, which turns one
instance into a class -- or a caller who hits the `article` skeleton without the
vault skill in context and believes it.
