---
name: using-passenger
description: |
  Use when reading or driving web pages through the passenger MCP server -- its
  `open_lane`, `script`, `show_browser`, `list_tabs` and `close_tabs` tools.
  There is no `fetch` and no extraction: `script` is the only door onto a page,
  and reading one is the caller's to write. Covers opening a lane before the
  first call, the recipes for reading a page (including `walker.js`, which is
  in this directory), what the `blocked` verdict does and does not catch,
  recognising a login wall or captcha the tool cannot name and handing the page
  to a human, why a read is only the first screen, why reading beats driving,
  and what the tool will not remember for you. Use it before the first call in
  a session, and whenever a read comes back thinner than the page looked.
---

# Using passenger

`passenger` reaches web pages through a real, logged-in Chrome that sites
cannot distinguish from an ordinary browser. Reach for it over a plain HTTP
fetch when a page needs a login, sits behind anti-bot protection, or renders
its content with JavaScript.

This skill is the operating knowledge: the things that are true before any
particular call, and the recipes for reading a page. What each argument means
is in the tool schemas and is not repeated here.

## Open a lane first

    lane = open_lane()

Every tab-touching tool takes it. A lane owns the tabs opened in it: no other
caller can see them, list them or close them, and nothing you do reaches
theirs. This matters more than it sounds -- one Chrome is shared by every agent
on the machine, including your own subagents, and the tab-closing verb used to
take no argument at all: it closed everything but one blank tab, whoever was
driving it.

A lane collects itself after **30 minutes with no calls**, closing its tabs.
Every call naming the lane restarts that clock, so work in progress is safe;
what is not safe is a wait you start and then leave. Before asking a human for
something slow, say how long you are prepared to wait:

    set_ttl(lane, 120)                     # minutes
    show_browser(lane, ttl_minutes=120)    # or say it as you ask

Say `destroy_lane(lane)` when you are finished, rather than leaving tabs parked
until the clock reaches them.

A lane that ran out comes back as `LANE_NOT_FOUND` on the next call, and its
tabs are already closed. Nothing is recoverable and retrying will not help:
open a new lane and start again. The usual way to get there is a handoff the
human took longer over than you allowed for, which is what `ttl_minutes` is
for.

## One door, and it hands you the page

There is no `fetch`. `script` is the whole surface onto a page: it navigates,
it drives, and it returns what you tell it to.

    script(lane, source="page.goto('https://example.com')\n"
                        "return page.inner_text('body')")

`page` is a real Playwright page. Omit `tab` and you get a fresh one; pass a
tab id from an earlier reply and you continue on it. Navigation, interaction
and reading are all one call, so a page you know how to handle costs exactly
one round trip.

**This server does not interpret pages.** It used to: there was a `fetch` with
an `article` mode and a `dom` mode, and choosing between them was the caller's
problem while getting them wrong was everyone's. Extraction is a judgement
about what a page *means*, and that judgement is yours -- you know what you
asked for and what you need from it. What this side does is navigate, measure
and get out of the way.

## Reading a page

Start with the cheapest thing that answers your question.

**The text, and nothing else.**

    return page.inner_text('body')

Good for most things. Fast, no markup, no links. This is also the escape hatch
for pages that defeat everything else -- 12306's ticket results render through
their own templating and `inner_text` is the only thing that sees them.

**Just the part you want.**

    return page.locator('#results').inner_text()
    return page.eval_on_selector_all('a[href]',
        "els => els.map(e => e.textContent.trim() + ' -> ' + e.href)")

Usually the right answer, and the one that costs you least context. You know
what you are looking for; the page does not.

**Markdown, with headings, lists, fenced code and resolved links.** Read
`walker.js` from this skill's directory and evaluate it:

    walker = <contents of skills/using-passenger/walker.js>
    return page.evaluate(walker)

It walks the live DOM, keeps only what `checkVisibility()` says is visible,
resolves every `href` against the document, emits `[label](url)` inline, fences
`pre` blocks, and tidies the result. It takes an optional
`[stripSelector, rootSelectors]` if you want to override where it starts or
what it discards.

It is not magic and it is not always right. Two known shapes:

- It keeps **everything visible under the root it picks**, so on a post with a
  comment thread you get the post and the comments. If you want the post alone,
  say so in your own selector.
- It picks its root from a short list of candidates (`main`, `article`,
  `#content`…). On a page whose furniture matches one of those thirty times
  over, it can start in the wrong place.

## The tool measures; you judge

Everything this server reports is something it *measured*: a character count, a
fraction of the viewport, a vendor's own markup. It never rules on what a page
means. That division is deliberate and load-bearing -- six mechanisms that
crossed it have been deleted from this codebase -- and it is why the reading
above is yours to do.

Every `script` reply carries a measurement of the tab you ended on:
`char_count` (the browser's own `innerText` length, not an extraction's), the
picture geometry, and the url and title. Read `char_count` against what you
expected. Nothing on this side is waiting to tell you the page was thin.

## Walls, and the ones the tool cannot see

A `blocked` result means a *known vendor's* markup was matched: Cloudflare,
reCAPTCHA, hCaptcha, DataDome, Arkose, PerimeterX, or a plain login wall. That
table is fixed. It does not grow, and it never will.

**Everything else arrives as an ordinary page.** A soft wall is not a `blocked`
verdict that is late; it is a `blocked` verdict that is never coming. You are
the one who notices.

What to notice -- examples, not a checklist:

- a short page whose text says *verify you are human*, *请完成验证*, *checking
  your browser*, *unusual traffic from your network*
- a login or signup prompt where an article or a listing was expected
- a page that is structurally fine and semantically empty: nav, footer, and a
  sentence in the middle

When you see one, you have seen enough. Do not run the same script again hoping
for a different verdict.

    show_browser(lane, tab, wait_seconds, notify_human, until)

Tell the user what is in the way. `notify_human` is for when they are not
watching this conversation. `until` decides what ends the wait:

- `closed` (default) returns when the human closes the viewer. That is a fact
  about the human, not about the page.
- `unblocked` polls the named tab until the vendor's signature stops matching.
  Stronger -- a human can close a window without solving anything -- but it
  needs a `tab`, and it only sees walls this tool can name.

Either way, **read the tab again with `script` and judge for yourself.**

`show_browser` is also how you ask for a human *deliberately*, not only in
answer to a `blocked` reply. A login you cannot complete is the same situation
as a captcha.

## A read is one screen

`script` runs against the page as it is. Anything the page defers until a
reader scrolls or clicks is not in what you return, **and nothing will tell you
so.** The page looks complete because it is complete -- for a reader who never
moved.

Before concluding you have a whole comment section or a whole listing, look in
what you read for the page's own account of what it kept back: a stated total
(`共 153 条评论`), an expander (`展开 12 条回复`), a pager, a "showing 20 of
619". Those strings are almost always already in front of you. Reaching what
they point at is more `script` -- and you are already there, with `page` in
hand.

## Pictures are not in the text

What lives in a photograph, a menu board, a chart or a comic was never text, so
such a page reads as *short* rather than as *truncated*.

`largest_image` is the biggest non-text thing the page renders, as a share of
the window. Roughly: `0.0` on a docs page, `0.10` on an illustrated article,
`0.27` on a comic, `0.38` on a three-photo note, above `1.0` on a marketing
hero. Read it against `char_count` -- **a large picture and little text is the
case worth acting on** -- and reach the picture itself in the same script:

    page.request.get(src)                 # when it is a URL
    page.locator(src).screenshot(path=…)  # when it is a selector

A small picture can still be the whole content (an xkcd comic measures 0.06),
which is why the number is handed to you rather than acted on.

## Prefer reading to driving

`script` is the way to reach a search box, a tab, the next page of a list. But
reading and driving are different kinds of act, not degrees of one.

After a human has navigated -- during a handoff, or just in their own browser
-- `script` against that tab costs nothing and is invisible to the site.
Synthetic clicks and fills are not: they have no cursor path and no keystroke
timing, and that is exactly what behavioural anti-bot systems score. Driving
spends the reputation of a session whose entire value is that it has never done
anything unusual.

So: navigate by hand where you can, drive only where you must, and prefer one
`script` that ends where you need to be over five that walk there.

## Housekeeping

Three verbs, and the differences between them are deliberate:

    close_tabs(lane, [tab, ...])   the ones you name
    close_all_tabs(lane)           every tab in your lane; the lane survives
    destroy_lane(lane)             the tabs, then the lane itself

There is no "close everything" you can reach by leaving an argument out. That
was the old shape and it is what closed other callers' tabs.

**Tabs accumulate faster now than they used to.** A `script` with no `tab`
opens a fresh one *every call*, so a batch of twenty pages driven one call each
leaves twenty tabs. Pass the `tab` back from the previous reply when you are
working through a list, and close what you are done with. The popups a page
opens for itself accumulate too, and so does every tab that came back
`blocked`, because that tab keeps its wall on purpose -- it is the one the
human needs.

Tabs left open cost memory in a browser meant to stay warm for weeks. The TTL
is a backstop for the calls you never got to make, not the plan.

**The screen is shared, and refcounted.** `show_browser` claims it; the viewer
stays up until every lane that claimed it has called `hide_browser`. So your
`hide_browser` cannot take the window away from someone else's human -- and
theirs cannot take it from yours.

**`orphan` is a junk drawer anyone may open.** Tabs a page opened by itself
join the lane that caused them, but a tab a *human* opened during a handoff has
no opener for Chrome to trace, so it lands in `orphan` -- readable and closable
by any caller, and never collected on a timer. `list_tabs("orphan")` is how you
look, and looking first is the whole etiquette: somebody may be halfway through
a login in there.

**What lanes do not isolate.** One profile means one Chrome and one attach, and
attaching initialises every open tab. So a tab wedged mid-navigation in *any*
lane slows or fails calls in every lane, and freeing it can stop a navigation
another lane was making. Lanes partition ownership, not availability. When it
happens the tool says which lanes it touched; it cannot prevent it.

`browser_status` reports `wedged:` for exactly this: `none`, or a count per
kind. Read it when calls have gone slow for no reason you can see -- the tab
doing it is usually not yours, and the count is the only thing that says so.

## The tool remembers nothing about a site

Your lane and its tabs are bookkeeping, and they are the only thing kept
between calls -- you can read all of it back with `list_tabs`, and it is gone
when the browser restarts. Nothing else is remembered. The tool will not learn
that this site walls the third request, that this listing needs its own
selector, that this domain redirects logged-out readers to a signup page.

**That is yours to remember**, in your own memory or in a site-scoped skill.
Anything durable you discover about a *site* belongs there -- including the
selector that reads it, which is now the most valuable thing you can write
down. A tool that remembered it would be a second memory owned by the wrong
party: invisible to you, unexplainable, and revisable only by surprise.
