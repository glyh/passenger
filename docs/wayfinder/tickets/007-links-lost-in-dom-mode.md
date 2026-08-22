---
id: 007
title: A listing read through dom mode has no link targets
labels: [wayfinder:research]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

`dom_text` reads `innerText`. Text is all it can return, so every `href`
on the page is discarded. `article_text` keeps links -- trafilatura is
called with `include_links=True` -- but trafilatura finds nothing in a JS
app, which is the documented reason `dom` exists at all. The mode that
can see a single-page app's content is the mode that cannot see where it
points, and the mode that keeps the pointers cannot see the content.

(Premise corrected after this was written: `page.content()` is the rendered
DOM, so trafilatura is not blind to a JS app -- it discards the listing as
boilerplate. See [Whether defuddle belongs alongside trafilatura as an extract
mode](009-defuddle-as-a-mode.md).)

For a document that costs nothing. For a *listing* it is the whole
point: a search result page is not prose, it is forty links with labels
attached, and the labels alone are not actionable.

The case that surfaced it: building a xiaohongshu recipe on top of this
tool, in place of a third-party MCP server. Search works. Logged in,
`https://www.xiaohongshu.com/search_result?keyword=<q>`, `mode=dom`
returns roughly forty result cards -- title, author, date, like count --
as one flat run of text. `mode=article` on the same URL returns the ICP
footer and nothing else. So the agent can read what the top results
*are* and cannot open any of them.

Three things close off every workaround:

- Note ids are opaque (`6a87a102000000003a02d724`) and unguessable.
- An id alone is not enough. `/explore/<id>` without the `xsec_token`
  that rides in the card's query string does not 404 -- it silently
  redirects to the caller's personalised feed and returns a full,
  normal-looking page of unrelated notes. The token is load-bearing, and
  it lives only in the href.
- Nothing indexes the site from outside. `site:xiaohongshu.com` on Baidu
  returns zero results; Bing was in a challenge loop; the WebSearch tool
  returned only `/explore` landing URLs.

What unblocked it was a human pasting an app share link into the
conversation, which resolved to the canonical URL with its token
attached. Note the difference from [Reaching content that sits behind an
interaction](004-driving-the-page.md): there, the fetch was defeated by a
page that had to be *driven*, and a human was already at the keyboard
because a challenge had been handed off. Here nothing was blocked and
nothing needed driving. The fetch succeeded, returned the right page,
and threw away the only part of it that was navigable.

To decide:

1. Whether `dom` should emit links at all. A DOM walk that renders `<a>`
   as `[text](href)` instead of bare `innerText` would keep the shape at
   the cost of a real extractor rather than one `evaluate` call. The
   cheaper half-measure -- appending a deduplicated link list after the
   text -- loses which label goes with which target, which on a listing
   is most of the information.
2. What a link is worth against what it costs. Forty cards is forty
   URLs, each with a long signed query string, and this interacts
   directly with the unbounded-fetch problem already in the map's Fog:
   the tokens can easily outweigh the text they annotate. A links-only
   mode, or a flag, may be the honest answer rather than changing `dom`
   for every caller.
3. Whether query strings survive. The instinct on a scraper is to
   normalise a URL down to its path; the `xsec_token` case says that
   instinct would produce URLs that look right and silently fetch the
   wrong page.
4. Whether resolving relative hrefs against the document URL belongs
   here. `/explore/<id>?...` is useless to a caller who does not know
   the origin, and the caller often will not.

## Answer

`dom` emits links, inline, always -- and the walk that emits them fixed a
second defect nobody had noticed.

**1. Links, inline, no flag.** `[label](url)` in the text where the anchor
sat, not a list appended afterwards: on a listing the pairing *is* the
information. No `--links` flag and no links-only mode. `article` has
always been called with `include_links=True`, so the asymmetry was the
bug -- one mode kept pointers and the other threw them away, and a caller
had no way to know which they were about to get. A flag defaulting off
leaves the agent unable to learn it should be on; defaulting on is dead
weight.

**2. The clone was the real bug.** `dom_text` read `innerText` off
`document.cloneNode(true)`. A detached node is not rendered, and
`innerText` on an unrendered node is defined to fall back to
`textContent` -- verified directly: `<div>one</div><div>two</div>` gives
`one\ntwo` live and `onetwo` on the clone. So `dom` never had block
boundaries at all; the line structure it appeared to have was the *source
HTML's* own whitespace, which is why it survived on Wikipedia (680 lines)
and vanished on a minified JS-rendered page. That is the "one flat run of
text" in the question, and it was never about links. `dom` now walks the
live document -- block tags for boundaries, `checkVisibility()` for what
counts as visible, `<pre>` whitespace kept.

**3. What it costs.** Measured on the same five saved pages as ticket 009,
characters of extracted text:

| page | before | after | links | lines before → after |
|---|---|---|---|---|
| xiaohongshu search | 1,502 | 11,042 | 70 | 1 → 93 |
| Hacker News front page | 3,767 | 16,266 | 228 | 3 → 127 |
| Wikipedia article | 75,174 | 130,690 | 741 | 680 → 1,221 |
| Python docs | 42,585 | 49,691 | 97 | 1,240 → 1,103 |
| react.dev tutorial | 67,898 | 69,142 | 14 | 1,178 → 1,212 |

+2% on a document, +9x on a listing. The blowup tracks link density,
which is the same axis along which links are worth having -- the pages
that grow most are the ones that *are* links. For scale, `article` on that
Wikipedia page, which has always kept its links, is 160,317 characters:
larger than the linked DOM text. So this does not create the unbounded
output problem in the map's Fog, and that problem is not solved by
blinding one mode.

Two rules keep the cost honest. A label-less anchor is dropped when
something else on the page points at the same URL -- that is the
cover-image anchor repeating its card's title link, 20 of them on the
xiaohongshu page. It is *kept* when its URL appears nowhere else, which
saved the one search result whose card is a bare cover image. And an
anchor with no text is labelled from `aria-label`, `title`, or a child
`img[alt]` before being judged.

**4. Targets are passed through whole, resolved and unnormalised.** `a.href`
gives the absolute URL resolved against the document, which point 4 asked
for and which HN needs (`item?id=…` is relative). Nothing is stripped:
`?xsec_token=…` is not decoration, it is a signed capability, and a
normalised xiaohongshu URL does not 404 -- it silently redirects to the
caller's own feed and returns a plausible page of unrelated notes. Only
`javascript:`, `mailto:` and fragment-only hrefs are skipped, the last
because `a.href` turns `#section` into a link back to the same page.

**5. Link markup must not be counted as content.** A URL segments into a
dozen or more "words": the Wikipedia DOM text went from 11,565 real words
to 17,291 counted. That feeds `choose`'s yield ratio *and* `min_words`,
which decides a page was blocked. Left alone it would have flipped the
xiaohongshu search page from `article` to `dom` -- the outcome one wants,
arrived at by measuring markup, which would then have flipped something
else the wrong way later. `text.unlinked()` strips the target half before
counting, and both `choose` and `Extraction.word_count` measure through
it. `auto`'s choice is unchanged on all five pages.

What this does *not* fix: `auto` still returns the ICP footer on the very
page that prompted the ticket. Unlinked, `article` yields 251 words against
`dom`'s 646 -- a ratio of 0.39, just clear of the 0.35 floor. Reaching the
cards still means asking for `mode=dom` by name. Split out as [A listing
clears the yield floor on a footer](011-listing-clears-the-yield-floor.md).
