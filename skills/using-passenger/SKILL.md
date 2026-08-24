---
name: using-passenger
description: |
  Use when reading or driving web pages through the passenger MCP server --
  `openLane`, `script`, `showBrowser`, `listTabs`, `closeTabs`. Scripts are C#
  against an async Playwright, and `script` is the only door onto a page: no
  fetch, no extraction, nothing here interprets a page for you. Covers what to
  do before the first call, reading a page cheaply and what the `markdown.js`,
  `unstrip-asides.js` and `pictures.js` recipes in `scripts/` are for, what the
  `blocked` verdict catches and what it never will, recognising a login wall or
  captcha the tool cannot name and handing the page to a human, why a read is
  only the first screen and why a picture-borne page reads short rather than
  truncated, what driving spends that reading does not, and what the tool will
  not remember for you. Read it before the first call in a session, and again
  whenever a read comes back thinner than the page looked.
---

# Using passenger

`passenger` reaches web pages through a real, logged-in Chrome that sites
cannot distinguish from an ordinary browser. Reach for it over a plain HTTP
fetch when a page needs a login, sits behind anti-bot protection, or renders
its content with JavaScript.

**This file is the judgement**: what is true before any particular call, and
what to notice once a page is in front of you. The mechanics live in four
files under `references/`, and none of them are worth opening until you want
one:

| what you are doing | open |
|---|---|
| getting the text, the markdown, or the page's own JSON | `references/reading-a-page.md` |
| a page whose content is photographs, menus or charts | `references/pictures.md` |
| writing the C#: strings, `await`, types, what cannot cross back | `references/writing-scripts.md` |
| tabs piling up, a wedged browser, a shared screen, `orphan` | `references/tabs-and-lanes.md` |

The recipes those files run -- `markdown.js`, `unstrip-asides.js`,
`pictures.js` -- are in `scripts/`. What each tool *argument* means is in the
tool schemas, and is repeated nowhere here.

**The server runs on your machine, in your filesystem.** A script's `File.*`
calls land on the same disk your other tools see, in both directions: read a
recipe off its real path instead of pasting it into a script, and write bytes
with `File.WriteAllBytesAsync` to a path you can then open yourself. A
screenshot or a downloaded image does not have to cross back as JSON.

## Open a lane first

    lane = openLane()

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

    setTtl(lane, 120)                     # minutes
    showBrowser(lane, ttlMinutes: 120)    # or say it as you ask

Say `destroyLane(lane)` when you are finished, rather than leaving tabs parked
until the clock reaches them. A lane that ran out comes back `LANE_NOT_FOUND`
with its tabs already closed: nothing is recoverable, so open a new one and
start again.

## One door, and it hands you the page

There is no `fetch`. `script` is the whole surface onto a page: it navigates,
it drives, and it returns what you tell it to.

    script(lane, source: """
        await Page.GotoAsync("https://example.com");
        return await Page.InnerTextAsync("body");
    """)

`Page` is a real Playwright `IPage`. Omit `tab` and you get a fresh one; pass a
tab id from an earlier reply and you continue on it. Navigation, interaction
and reading are all one call, so a page you know how to handle costs exactly
one round trip.

**Three things about the C# here**, and they account for nearly every first-try
failure:

- **`Page`, capitalised.** It is a member, so it follows C#'s convention like
  everything else you will call on it. `page` does not compile.
- **Everything is awaited.** Playwright .NET has no synchronous API, so
  `Page.GotoAsync(url)` without `await` hands you a `Task`, not a page.
- **`return` at the top level is fine.** No wrapper, no method, no class.

The ones that bite after it compiles -- verbatim strings for JavaScript, a
nested `await` that will not build, the type argument that is not optional, the
live handles that cannot cross back -- are in `references/writing-scripts.md`.

**This server does not interpret pages.** It used to: there was a `fetch` with
an `article` mode and a `dom` mode, and choosing between them was the caller's
problem while getting them wrong was everyone's. Extraction is a judgement
about what a page *means*, and that judgement is yours -- you know what you
asked for and what you need from it. What this side does is navigate, measure
and get out of the way.

## Reading a page

Start with the cheapest thing that answers your question.

    return await Page.InnerTextAsync("body");                 // the text, and nothing else
    return await Page.Locator("#results").InnerTextAsync();   // just the part you want

Those two answer most questions, and the second costs you the least context:
you know what you are looking for, and the page does not. Two more are worth
knowing by name, both in `references/reading-a-page.md`:

- **`Page.APIRequest`**, which often reaches the site's own JSON without
  rendering the page at all -- a `__INITIAL_STATE__` blob, or a preload link in
  the `<head>` -- and is the cheapest and most structured read there is when a
  site has one. Look for it before writing selectors.
- **`markdown.js`**, when structure is the thing you need: headings, lists,
  fenced code, and every link resolved and inline.

**A short read comes back; a long one goes to disk.** A tool reply is JSON, so
a returned page arrives quoted and escaped, on one line, and all of it is in
your context whether you wanted it or not. Write it out with
`File.WriteAllTextAsync` and return the path and the length instead -- the
length being the thing you read against what you expected.

## The tool measures; you judge

The one thing this server reports about a page is something it *measured*: a
vendor's own markup, matched against a fixed table. It never rules on what a
page means. That division is deliberate and load-bearing -- six mechanisms that
crossed it have been deleted from this codebase -- and it is why the reading
above is yours to do.

**A `script` reply carries what you returned, and nothing about the page except
a wall.** It used to carry a measurement of the tab you ended on -- a character
count, the picture geometry, the url and title -- and that is gone. Whatever
you want to know about the page, return it: `Page.Url`,
`await Page.TitleAsync()`, `(await Page.InnerTextAsync("body")).Length`. They
cost you nothing extra, because your script is already there.

The consequence is worth stating plainly, because nothing else will state it:
**a page that reads short will not tell you it was picture-borne**, and no
field in the reply hints at it.

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

    showBrowser(lane, tab, waitSeconds, notifyHuman, until)

Tell the user what is in the way. `notifyHuman` is for when they are not
watching this conversation. `until` decides what ends the wait:

- `closed` (default) returns when the human closes the viewer. That is a fact
  about the human, not about the page.
- `unblocked` polls the named tab until the vendor's signature stops matching.
  Stronger -- a human can close a window without solving anything -- but it
  needs a `tab`, and it only sees walls this tool can name.

Either way, **read the tab again with `script` and judge for yourself.**

`showBrowser` is also how you ask for a human *deliberately*, not only in
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
they point at is more `script` -- and you are already there, with `Page` in
hand.

## Pictures are not in the text

What lives in a photograph, a menu board, a chart or a comic was never text, so
such a page reads as *short* rather than as *truncated*, and no field in the
reply distinguishes the two. If you did not measure the pictures, nobody did.

`scripts/pictures.js` measures them -- the biggest visible picture as a share
of the window, how many clear a tenth of it, and how to reach the biggest one
-- and `references/pictures.md` says how to run it, how to read the number, and
how to get the bytes onto your disk. **A large picture and little text is the
case worth acting on**, so measure the text in the same script and compare the
two yourself.

## Prefer reading to driving

`script` is the way to reach a search box, a tab, the next page of a list. But
reading and driving are different kinds of act, not degrees of one.

After a human has navigated -- during a handoff, or just in their own browser
-- `script` against that tab costs nothing and is invisible to the site. So
does `Page.APIRequest` against a URL. Synthetic clicks and fills are not: they
have no cursor path and no keystroke timing, and that is exactly what
behavioural anti-bot systems score. Driving spends the reputation of a session
whose entire value is that it has never done anything unusual.

**That reputation is a budget, and it is not yours alone.** Sites meter per
account, not per lane and not per session, so a brand-new lane on its first
page of the day can be thrown out on its first click because something else
spent the allowance hours earlier. And the throttle rarely announces itself:
one expansion too many and the tab is navigated away, after which the selectors
match nothing and the page reads exactly like an item nobody ever replied to.
**An empty result after a burst of driving is a fact about you, not about the
page.**

So spend it last. Take everything reachable without clicking first, and put the
one operation you know is expensive at the end of the task, where being cut off
costs you that step instead of the whole run.

And: navigate by hand where you can, drive only where you must, and prefer one
`script` that ends where you need to be over five that walk there.

## Close what you opened

    closeTabs(lane, [tab, ...])    the ones you name
    closeAllTabs(lane)             every tab in your lane; the lane survives
    destroyLane(lane)              the tabs, then the lane itself

A `script` with no `tab` opens a fresh one *every call*, so a batch of twenty
pages driven one call each leaves twenty tabs in a browser meant to stay warm
for weeks. Pass the `tab` back when you are working through a list, and close
what you are done with; the TTL is a backstop for the calls you never got to
make, not the plan. `references/tabs-and-lanes.md` has the rest: the shared
screen, the `orphan` drawer a human's tabs land in, and why a tab wedged in
someone else's lane still costs you.

## The tool remembers nothing about a site

Your lane and its tabs are bookkeeping, and they are the only thing kept
between calls -- you can read all of it back with `listTabs`, and it is gone
when the browser restarts. Nothing else is remembered. The tool will not learn
that this site walls the third request, that this listing needs its own
selector, that this domain redirects logged-out readers to a signup page.

**That is yours to remember**, in your own memory or in a site-scoped skill.
Anything durable you discover about a *site* belongs there -- including the
selector that reads it, which is now the most valuable thing you can write
down. A tool that remembered it would be a second memory owned by the wrong
party: invisible to you, unexplainable, and revisable only by surprise.
