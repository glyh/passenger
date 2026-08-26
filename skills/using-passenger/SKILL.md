---
name: using-passenger
description: |
  Use when reading or driving a web page through the passenger MCP server:
  `openLane`, `script`, `showBrowser`, `listTabs`, `closeTabs`. Reaches pages
  through a real logged-in Chrome, so use it when a page needs a login, sits
  behind anti-bot protection, or renders its content with JavaScript. Triggers
  include: "read this page", "log in and get X", "this site blocks me", "the
  fetch came back empty", "scrape this listing", "a captcha is in the way",
  plus any first call in a session and any read that returns less than the page
  appeared to hold.
  Does NOT cover site-specific mechanics — selectors, that site's silent
  failures, its login state — which belong in that site's own skill. To turn
  HTML you already have into markdown, use `html-to-markdown`. To write down
  what you learned about a site, use `passenger-skill-authoring`.
---

# Using passenger

passenger reaches web pages through a real, logged-in Chrome that sites cannot
distinguish from an ordinary browser. Prefer it over a plain HTTP fetch when a
page requires a login, sits behind anti-bot protection, or renders its content
with JavaScript.

This file is the decision content: what holds before any call, and what to
check once a page is in front of you. Mechanics live in `references/`.

| Task | File |
| --- | --- |
| Get text, markdown, or the page's own JSON | `references/reading-a-page.md` |
| Page whose content is photographs, menus, charts | `references/pictures.md` |
| Write the JavaScript: scope, traps, what can cross back | `references/writing-scripts.md` |
| Tabs piling up, wedged browser, shared screen, `orphan` | `references/tabs-and-lanes.md` |

Recipes those files run — `markdown.js`, `unstrip-asides.js`, `pictures.js` —
are in `scripts/`. Per-argument meaning is in the tool schemas and is not
duplicated here.

## The server runs on your machine, on your filesystem

A script gets `fs` (`node:fs/promises`) pointed at the same disk your other
tools see. This works in both directions:

- Read a recipe from its real path instead of pasting it into a script.
- `fs.writeFile` bytes to a path you can open yourself. A screenshot or a
  downloaded image never has to cross back as JSON.
- Put a file *into* a page: `setInputFiles` takes a path on this same disk.

## Open a lane first

```
lane = openLane()
```

Every tab-touching tool takes it. A lane owns the tabs opened in it: no other
caller can see, list, or close them, and nothing you do reaches theirs.

This matters because one Chrome is shared by every agent on the machine,
including your own subagents. The tab-closing verb previously took no argument
and closed everything but one blank tab, whoever was driving it.

**A lane collects itself after 30 minutes with no calls**, closing its tabs.
Every call naming the lane restarts that clock. Work in progress is therefore
safe; a wait you start and then leave is not. Before asking a human for
something slow, declare how long you will wait:

```
setTtl(lane, 120)                     # minutes
showBrowser(lane, ttlMinutes: 120)    # or declare it as you ask
```

Call `destroyLane(lane)` when finished rather than leaving tabs parked until
the clock reaches them. **A lane that expired returns `LANE_NOT_FOUND` with its
tabs already closed. Nothing is recoverable and retrying will not help** — open
a new lane and start again.

## One door: `script`

There is no `fetch` tool. `script` is the entire surface onto a page: it
navigates, drives, and returns what you tell it to.

```js
script(lane, source: """
    await Page.goto("https://example.com");
    return await Page.innerText("body");
""")
```

The source is plain JavaScript and `Page` is Playwright's own `Page` — the API
you already know, not a binding of it. Omit `tab` for a fresh one; pass a tab
id from an earlier reply to continue on it. Navigation, interaction, and
reading are one call, so a page you know how to handle costs one round trip.

Two rules account for nearly every first-try failure:

- **`Page` is capitalised.** It is the one name this side introduces. `page` is
  not defined.
- **`return` and top-level `await` both work.** Your source is wrapped in an
  async function before it runs. Do not add `(async () => {...})()` yourself.

The traps that bite later — `Page.evaluate` silently returning `undefined` when
handed a string, what is in scope, which values cannot cross back — are in
`references/writing-scripts.md`.

**Open it when:** a script fails to parse, a call throws anything other than a
wall or a timeout, or an `evaluate` returns `undefined`.

**This server does not interpret pages.** It previously did, via a `fetch` tool
with `article` and `dom` modes; choosing between them was the caller's problem
and getting it wrong was everyone's. Extraction is a judgement about what a
page *means*, and that judgement is yours. This side navigates, measures, and
gets out of the way.

## Reading a page

Start with the cheapest read that answers the question.

```js
return await Page.innerText("body");                 // the text, nothing else
return await Page.locator("#results").innerText();   // only the part you want
```

Those answer most questions, and the second costs the least context: you know
what you are looking for and the page does not. Two more are worth knowing by
name, both detailed in `references/reading-a-page.md`:

- **`Page.request`** often reaches the site's own JSON without rendering the
  page at all — an `__INITIAL_STATE__` blob, or a preload link in the `<head>`.
  This is the cheapest and most structured read available when a site has one.
  **Look for it before writing selectors.**
- **`markdown.js`** when you need structure: headings, lists, fenced code, and
  every link resolved and inline. It reads the *live* page, so it sees what
  JavaScript drew. For a forum thread, or when you want frontmatter, hand the
  HTML to the `html-to-markdown` skill instead — `references/reading-a-page.md`
  documents the seam with measurements on the same page.

**Open `references/reading-a-page.md` when:** before writing a selector by
hand, or before assuming a page has no structured JSON of its own.

**Short reads return; long reads go to disk.** A tool reply is JSON, so a
returned page arrives quoted and escaped on one line, and all of it enters your
context whether or not you wanted it. Write it out with `fs.writeFile` and
return the path plus the length. The length is what you check against
expectation.

## The tool measures; you judge

The one thing this server reports about a page is measured: a vendor's own
markup, matched against a fixed table. It never rules on what a page means.
That division is load-bearing — six mechanisms that crossed it have been
deleted from this codebase — and it is why the reading above is yours to do.

A `script` reply is flat. It carries what you returned, plus nothing about the
page except a wall:

| Field | When | Meaning |
| --- | --- | --- |
| `tab` | always | the handle to pass back to continue on this page |
| `returned` | on success | what your script returned; absent if it did not finish |
| `code`, `error`, `where` | on failure | their presence *is* the failure. Test `if (r.error)`. `where` cites your own line |
| `wallChecked` | always | `false` means you passed `checkWall: false` |
| `blocked` | wall matched only | test `if (r.blocked)` |

The reply previously carried a measurement of the tab you ended on — character
count, picture geometry, url, title. That is gone. Whatever you want to know
about the page, return it: `Page.url()`, `await Page.title()`,
`(await Page.innerText("body")).length`. These cost nothing extra because your
script is already there.

Consequence, since nothing else states it: **a page that reads short will not
tell you it was picture-borne.** No field in the reply hints at it.

## Walls, including the ones the tool cannot see

`blocked` means a *known vendor's* markup matched: Cloudflare, reCAPTCHA,
hCaptcha, DataDome, Arkose, PerimeterX, or a plain login wall. **That table is
fixed. It does not grow.**

**Everything else arrives as an ordinary page.** A soft wall is not a late
`blocked` verdict; it is a verdict that is never coming. You are the one who
notices.

Check for — examples, not a checklist:

- a short page whose text says *verify you are human*, *请完成验证*, *checking
  your browser*, *unusual traffic from your network*
- a login or signup prompt where an article or listing was expected
- a page that is structurally complete and semantically empty: nav, footer, and
  one sentence in the middle

**When you see one, stop. Do not re-run the same script hoping for a different
verdict.**

```
showBrowser(lane, tab, waitSeconds, notifyHuman, until)
```

Tell the user what is in the way. `notifyHuman` is for when they are not
watching this conversation. `until` decides what ends the wait:

- `closed` (default) returns when the human closes the viewer. That is a fact
  about the human, not about the page.
- `unblocked` polls the named tab until the vendor's signature stops matching.
  Stronger, since a human can close a window without solving anything — but it
  requires a `tab` and only sees walls this tool can name.

Either way, **read the tab again with `script` and judge for yourself.**

`showBrowser` is also how you request a human *deliberately*, not only in
response to `blocked`. A login you cannot complete is the same situation as a
captcha.

## A read is one screen

`script` runs against the page as it is. Anything the page defers until a
reader scrolls or clicks is absent from what you return, **and nothing reports
this**. The page looks complete because it is complete — for a reader who never
moved.

Before concluding you have a whole comment section or a whole listing, search
what you read for the page's own account of what it withheld: a stated total
(`共 153 条评论`), an expander (`展开 12 条回复`), a pager, a "showing 20 of
619". Those strings are almost always already in front of you. Reaching what
they point at is more `script`, and you are already there with `Page` in hand.

## Pictures are not in the text

Content living in a photograph, menu board, chart, or comic was never text, so
such a page reads as *short* rather than *truncated*, and no field distinguishes
the two. **If you did not measure the pictures, nobody did.**

`scripts/pictures.js` measures them: the largest visible picture as a share of
the window, how many clear a tenth of it, and how to reach the largest.
`references/pictures.md` covers running it, reading the number, and getting the
bytes onto disk. **Large picture plus little text is the case to act on**, so
measure the text in the same script and compare them yourself.

**Open `references/pictures.md` when:** a read comes back short and you have not
yet measured the pictures. A menu, price list, chart, or comic panel never was
text.

## Prefer reading to driving

`script` is how you reach a search box, a tab, the next page of a list. But
reading and driving are different kinds of act, not degrees of one.

Reading is invisible: `script` against a tab a human already navigated costs
nothing, and so does `Page.request` against a URL. **Synthetic clicks and fills
are not invisible.** They have no cursor path and no keystroke timing, which is
exactly what behavioural anti-bot systems score. Driving spends the reputation
of a session whose entire value is that it has never done anything unusual.

**That reputation is a shared budget.** Sites meter per account, not per lane
and not per session, so a brand-new lane on its first page of the day can be
thrown out on its first click because something else spent the allowance hours
earlier. The throttle rarely announces itself: one expansion too many and the
tab is navigated away, after which selectors match nothing and the page reads
exactly like an item nobody ever replied to. **An empty result after a burst of
driving is a fact about you, not about the page.**

Therefore:

- Take everything reachable without clicking first.
- Put the operation you know is expensive at the end of the task, where being
  cut off costs that step instead of the whole run.
- Navigate by hand where you can, drive only where you must, and prefer one
  `script` that ends where you need to be over five that walk there.

## Close what you opened

```
closeTabs(lane, [tab, ...])    the ones you name
closeAllTabs(lane)             every tab in your lane; the lane survives
destroyLane(lane)              the tabs, then the lane itself
```

**A `script` with no `tab` opens a fresh one on every call**, so twenty pages
driven one call each leave twenty tabs in a browser meant to stay warm for
weeks. Pass the `tab` back when working through a list and close what you are
done with. The TTL is a backstop for calls you never got to make, not the plan.

`references/tabs-and-lanes.md` has the rest: the shared screen, the `orphan`
drawer a human's tabs land in, and why a tab wedged in another lane still costs
you.

**Open it when:** tabs are piling up, a call returns `wedged` or
`LANE_NOT_FOUND`, or you need to hand the screen to a human without stepping on
another caller's tabs.

## The tool remembers nothing about a site

Your lane and its tabs are the only state kept between calls. You can read all
of it back with `listTabs`, and it is gone when the browser restarts.

Nothing else is remembered. The tool will not learn that this site walls the
third request, that this listing needs its own selector, or that this domain
redirects logged-out readers to a signup page.

**That is yours to remember**, in your own memory or in a site-scoped skill —
including the selector that reads it, which is the most valuable thing you can
write down. A tool that remembered it would be a second memory owned by the
wrong party: invisible to you, unexplainable, and revisable only by surprise.
