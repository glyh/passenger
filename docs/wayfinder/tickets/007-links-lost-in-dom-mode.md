---
id: 007
title: A listing read through dom mode has no link targets
labels: [wayfinder:research]
status: open
assignee:
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
