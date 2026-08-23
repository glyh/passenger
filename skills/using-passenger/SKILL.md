---
name: using-passenger
description: Use when fetching or driving web pages through the passenger MCP server -- its `open_lane`, `fetch`, `script`, `show_browser`, `list_tabs` and `close_tabs` tools. Covers opening a lane before the first fetch, what the `blocked` verdict does and does not catch, recognising a login wall or captcha the tool cannot name and handing the page to a human, why a fetch is only the first screen, why reading a page beats driving it, and what the tool will not remember for you. Use it before the first call in a session, and whenever a fetch comes back thinner than the page looked.
---

# Using passenger

`passenger` fetches pages through a real, logged-in Chrome that sites
cannot distinguish from an ordinary browser. Reach for it over a plain HTTP
fetch when a page needs a login, sits behind anti-bot protection, or renders
its content with JavaScript.

This skill is the operating knowledge: the things that are true before any
particular call. What each argument means is in the tool schemas, and is not
repeated here -- read `mode`'s description before choosing one, because that
choice is the difference between a listing and its footer.

## Open a lane first

    lane = open_lane()

Every tab-touching tool takes it. A lane owns the tabs opened in it: no other
caller can see them, list them or close them, and nothing you do reaches
theirs. This matters more than it sounds -- one Chrome is shared by every
agent on the machine, including your own subagents, and the tab-closing verb
used to take no argument at all: it closed everything but one blank tab,
whoever was driving it.

A lane collects itself after **30 minutes with no calls**, closing its tabs.
Every call naming the lane restarts that clock, so work in progress is safe;
what is not safe is a wait you start and then leave. Before asking a human for
something slow, say how long you are prepared to wait:

    set_ttl(lane, 120)              # minutes
    show_browser(lane, ttl_minutes=120)   # or say it as you ask

Say `destroy_lane(lane)` when you are finished, rather than leaving tabs
parked until the clock reaches them.

A lane that ran out comes back as `LANE_NOT_FOUND` on the next call, and its
tabs are already closed. Nothing is recoverable and retrying will not help:
open a new lane and start the work again. The usual way to get there is a
handoff the human took longer over than you allowed for, which is what
`ttl_minutes` is for.

## The tool measures; you judge

Everything this server reports is something it *measured*: a character count,
a fraction of the viewport, a vendor's own markup. It never rules on what a
page means. That division is deliberate and load-bearing -- four mechanisms
that crossed it have been deleted from this codebase -- and it means the
judgements below are yours to make. Nothing on that side is waiting to make
them for you.

## Walls, and the ones the tool cannot see

A `blocked` result means a *known vendor's* markup was matched: Cloudflare,
reCAPTCHA, hCaptcha, DataDome, Arkose, PerimeterX, or a plain login wall.
That table is fixed. It does not grow, and it never will.

**Everything else arrives as ordinary `fetched` content.** A soft wall is not
a `blocked` verdict that is late; it is a `blocked` verdict that is never
coming. You are the one who notices.

What to notice -- examples, not a checklist:

- a short page whose text says *verify you are human*, *请完成验证*, *checking
  your browser*, *unusual traffic from your network*
- a login or signup prompt where an article or a listing was expected
- a page that is structurally fine and semantically empty: nav, footer, and a
  sentence in the middle

When you see one, you have seen enough. Do not fetch again hoping for a
different verdict.

    show_browser(lane, tab, wait_seconds, notify_human)

Tell the user what is in the way. `notify_human` is for when they are not
watching this conversation. Then -- and this is the part most often missed --
**re-read the tab with `script` and judge for yourself.** `show_browser` never
inspects the page. It cannot tell you whether the challenge was solved; its
wait ends when the human closes the viewer, which is a fact about the human,
not about the page.

`show_browser` is also how you ask for a human *deliberately*, not only in
answer to a `blocked` reply. A login you cannot complete is the same situation
as a captcha.

## A fetch is one screen

`fetch` is goto, settle, read. Anything the page defers until a reader scrolls
or clicks is not in the result, **and nothing will tell you so.** The page
looks complete because it is complete -- for a reader who never moved.

Before concluding you have a whole comment section or a whole listing, look in
the markdown you were handed for the page's own account of what it kept back:
a stated total (`共 153 条评论`), an expander (`展开 12 条回复`), a pager, a
"showing 20 of 619". Those strings are almost always already in front of you.
Reaching what they point at is `script`.

## Pictures are not in the markdown

What lives in a photograph, a menu board, a chart or a comic was never in the
text, so such a page reads as *short* rather than as *truncated*.

`largest_image` is the biggest non-text thing the page renders, as a share of
the window. Roughly: `0.0` on a docs page, `0.10` on an illustrated article,
`0.27` on a comic, `0.38` on a three-photo note, above `1.0` on a marketing
hero. Read it against `char_count` -- **a large picture and little text is the
case worth acting on** -- and reach the picture itself with `script`:

    page.request.get(largest_image_src)              # when it is a URL
    page.locator(largest_image_src).screenshot(...)  # when it is a selector

A small picture can still be the whole content (an xkcd comic measures 0.06),
which is why the number is handed to you rather than acted on.

## Prefer reading to driving

`script` runs Playwright against a real tab, and it is the way to reach a
search box, a tab, the next page of a list. But reading and driving are
different kinds of act, not degrees of one.

After a human has navigated -- during a handoff, or just in their own browser
-- `script` against that tab costs nothing and is invisible to the site.
Synthetic clicks and fills are not: they have no cursor path and no keystroke
timing, and that is exactly what behavioural anti-bot systems score. Driving
spends the reputation of a session whose entire value is that it has never
done anything unusual.

So: navigate by hand where you can, drive only where you must, and prefer one
`script` that ends where you need to be over five that walk there.

## Housekeeping

Three verbs, and the differences between them are deliberate:

    close_tabs(lane, [tab, ...])   the ones you name
    close_all_tabs(lane)           every tab in your lane; the lane survives
    destroy_lane(lane)             the tabs, then the lane itself

There is no "close everything" you can reach by leaving an argument out. That
was the old shape and it is what closed other callers' tabs.

Repeated `fetch` calls in one lane reuse a single tab, so a long batch of them
leaves one. Three things do accumulate: `script` without a `tab`, which opens a
fresh one each call; the popups a page opens for itself; and every fetch that
came back `blocked`, because that tab keeps its wall on purpose -- it is the
one the human needs -- so the next fetch cannot reuse it.

Those are what to clean up; tabs left open cost memory in a browser meant to
stay warm for weeks. The TTL is a backstop for the calls you never got to
make, not the plan.

**The screen is shared, and refcounted.** `show_browser` claims it; the viewer
stays up until every lane that claimed it has called `hide_browser`. So your
`hide_browser` cannot take the window away from someone else's human -- and
theirs cannot take it from yours.

**`orphan` is a junk drawer anyone may open.** Tabs a page opened by itself
join the lane that caused them, but a tab a *human* opened during a handoff has
no opener for Chrome to trace, so it lands in `orphan` -- readable and closable
by any caller, and never collected on a timer. `list_tabs("orphan")` is how
you look, and looking first is the whole etiquette: somebody may be halfway
through a login in there.

**What lanes do not isolate.** One profile means one Chrome and one attach, and
attaching initialises every open tab. So a tab wedged mid-navigation in *any*
lane slows or fails calls in every lane, and freeing it can stop a navigation
another lane was making. Lanes partition ownership, not availability. When it
happens the tool says which lanes it touched; it cannot prevent it.

## The tool remembers nothing about a site

Your lane and its tabs are bookkeeping, and they are the only thing kept
between calls -- you can read all of it back with `list_tabs`, and it is gone
when the browser restarts. Nothing else is remembered. The tool will not learn
that this site walls the third request, that this listing needs `dom`, that
this domain redirects logged-out readers to a signup page.

**That is yours to remember**, in your own memory or in a site-scoped skill.
Anything durable you discover about a *site* belongs there. A tool that
remembered it would be a second memory owned by the wrong party: invisible to
you, unexplainable, and revisable only by surprise.
