---
name: using-passenger
description: |
  Use when reading or driving web pages through the passenger MCP server --
  its `openLane`, `script`, `showBrowser`, `listTabs` and `closeTabs` tools.
  Scripts are C# against an async Playwright. Covers opening a lane before the
  first call, the recipes for reading a page and for measuring its pictures
  (`markdown.js`, `unstrip-asides.js` and `pictures.js`, all in this directory
  -- best-effort recipes to read and adapt, not fixed APIs), what the `blocked`
  verdict does and does not catch, why a Sphinx or docutils page loses its
  footnotes and what to run first,
  recognising a login wall or captcha the tool cannot name and handing the
  page to a human, why a read is only the first screen, why reading beats
  driving, and what the tool will not remember for you. Use it before the
  first call in a session, and whenever a read comes back thinner than the
  page looked.
---

# Using passenger

`passenger` reaches web pages through a real, logged-in Chrome that sites
cannot distinguish from an ordinary browser. Reach for it over a plain HTTP
fetch when a page needs a login, sits behind anti-bot protection, or renders
its content with JavaScript.

This skill is the operating knowledge: the things that are true before any
particular call, and the recipes for reading a page. What each argument means
is in the tool schemas and is not repeated here.

**The server runs on your machine, in your filesystem.** A script's `File.*`
calls land on the same disk your other tools see, in both directions: read a
recipe like `markdown.js` from its real path instead of pasting it in (see
below), and write bytes with `File.WriteAllBytesAsync` to a path you can then
open yourself -- a screenshot or a downloaded image does not have to cross
back as JSON.

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
until the clock reaches them.

A lane that ran out comes back as `LANE_NOT_FOUND` on the next call, and its
tabs are already closed. Nothing is recoverable and retrying will not help:
open a new lane and start again. The usual way to get there is a handoff the
human took longer over than you allowed for, which is what `ttlMinutes` is for.

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

**Three things about writing C# here**, and they account for nearly every
first-try failure:

- **`Page`, capitalised.** It is a member, so it follows C#'s convention like
  everything else you will call on it. `page` does not compile.
- **Everything is awaited.** Playwright .NET has no synchronous API, so
  `Page.GotoAsync(url)` without `await` hands you a `Task`, not a page.
- **`return` at the top level is fine.** No wrapper, no method, no class.

**This server does not interpret pages.** It used to: there was a `fetch` with
an `article` mode and a `dom` mode, and choosing between them was the caller's
problem while getting them wrong was everyone's. Extraction is a judgement
about what a page *means*, and that judgement is yours -- you know what you
asked for and what you need from it. What this side does is navigate, measure
and get out of the way.

## Reading a page

Start with the cheapest thing that answers your question.

**The text, and nothing else.**

    return await Page.InnerTextAsync("body");

Good for most things. Fast, no markup, no links. This is also the escape hatch
for pages that defeat everything else -- 12306's ticket results render through
their own templating and `InnerText` is the only thing that sees them.

**Just the part you want.**

    return await Page.Locator("#results").InnerTextAsync();

    return await Page.EvalOnSelectorAllAsync<string[]>(
        "a[href]", "els => els.map(e => e.textContent.trim() + ' -> ' + e.href)");

Usually the right answer, and the one that costs you least context. You know
what you are looking for; the page does not.

**The type argument on `EvalOnSelectorAllAsync<T>` is required**, and forgetting
it is the single most common way this call fails. There is an overload without
it, so the compiler will not always save you: it returns `JsonElement`, which
crosses the boundary as a shape you did not intend. Say the type you want.

**Markdown, with headings, lists, fenced code and resolved links.** `markdown.js`
sits in this skill's directory, and **the server runs on your machine, in your
filesystem** -- so read it from disk rather than pasting its contents into the
script:

    var js = await File.ReadAllTextAsync("/path/to/skills/using-passenger/markdown.js");
    return await Page.EvaluateAsync<string>(js);

**For a whole page, write it out instead of returning it.** A tool reply is
JSON, so a returned string arrives quoted and escaped -- every newline as `\n`,
on one line, and the whole page in your context whether you wanted all of it or
not. The filesystem is shared, so hand it to yourself as a file and read what
you need:

    var js = await File.ReadAllTextAsync("/path/to/skills/using-passenger/markdown.js");
    var markdown = await Page.EvaluateAsync<string>(js);
    var path = "/tmp/pep8.md";              // yours to name; nothing here picks one
    await File.WriteAllTextAsync(path, markdown);
    return new Dictionary<string, object> { ["path"] = path, ["chars"] = markdown.Length };

Now the markdown is text on disk, and `chars` is there to read against what you
expected. Return the string directly for a short read; write it out for a long
one.

Use the actual path -- the one this file was read from, since `markdown.js` is
its sibling. Reading beats pasting for a reason sharper than convenience: a
tool call is JSON, and every backslash in the file has to survive that. The
regexes are full of them, and a transcription that doubles some and not others
either fails to parse or -- worse -- decodes an escape into the character it
names and hands the page something that is no longer JavaScript. The two
Unicode line separators used to do exactly that, ending a regex literal early
with `SyntaxError: Invalid regular expression: missing /`; they are built with
`new RegExp` now, so that particular one is gone, but the class is not. A file
read never crosses the boundary at all; the bytes on disk reach
`Page.EvaluateAsync` unchanged.

It walks the live DOM, keeps only what `checkVisibility()` says is visible,
resolves every `href` against the document, emits `[label](url)` inline, fences
`pre` blocks, and tidies the result. It takes an optional
`[stripSelector, rootSelectors]` if you want to override where it starts or
what it discards.

It runs in the page rather than on the server, which is why the port left it
untouched.

It is not magic and it is not always right. Two known shapes:

- It keeps **everything visible under the root it picks**, so on a post with a
  comment thread you get the post and the comments. If you want the post alone,
  say so in your own selector.
- It picks its root from a short list of candidates (`main`, `article`,
  `#content`…). On a page whose furniture matches one of those thirty times
  over, it can start in the wrong place.
- It strips a fixed list of furniture -- `nav`, `header`, `footer`, `aside` --
  and **something carrying content can be on that list**. Unlike the other two,
  this one does not show up in the character count. See below.

**On Sphinx and docutils pages, run `unstrip-asides.js` first or lose the
footnotes.** docutils emits footnotes and citations as `<aside class="footnote">`
and wraps groups of them in an outer `aside`, so `markdown.js` discards the
reference apparatus and keeps the prose that points at it. Measured on PEP 8:
45,389 characters against the page's own 45,407 -- an eighteen-character
shortfall for losing every footnote and the whole `## References` section, which
is exactly the number you were told to read against expectation. `unstrip-asides.js`
sits beside `markdown.js`, retags the content-bearing asides as `section` so the
strip list stops matching them, and returns how many it rescued. It is a
separate file because both of `aside`'s jobs are real -- on a news site it
genuinely is a sidebar -- so this is yours to opt into on the pages where it is
not:

    var fix = await File.ReadAllTextAsync("/path/to/skills/using-passenger/unstrip-asides.js");
    var js  = await File.ReadAllTextAsync("/path/to/skills/using-passenger/markdown.js");
    var rescued  = await Page.EvaluateAsync<int>(fix);      // 7 on PEP 8
    var markdown = await Page.EvaluateAsync<string>(js);

Run it on any page: it rescues nothing and changes nothing where there is
nothing to rescue (0 on theguardian.com's 22 asides), and running it twice
rescues 0 the second time. It mutates the live DOM, which is free on a tab you
opened to read and worth knowing about on a tab a human is working in.

**It is a recipe, not an API -- read it, and change it when it is wrong.** It is
a single arrow-function expression in a file you already have on disk, deliberately
literal so that it can be understood in one pass. Nothing here versions it or
depends on its internals: no C# calls into it, the reply carries only what your
script returned, and the two overrides it takes cover the common case rather
than every case. So when the root heuristic picks a decoy, or the strip list
discards something that was carrying the content, editing the source you just
read and evaluating that is a normal thing to do -- either in the string you
pass to `EvaluateAsync`, or by keeping your own copy for a site you come back
to. That is best-effort by design; it is not a contract you are working around.

**Do not restructure a script to avoid the compile.** Measured: after the
server's first call, compiling a script costs a flat ~40ms whatever it says --
an 11 KB source carrying the whole of `markdown.js` compiles in the same time
as a one-line one. It is noise beside a single navigation, and batching unrelated
work into one script to amortise it buys nothing while costing you the ability
to continue from where a failure left off.

## The tool measures; you judge

The one thing this server reports about a page is something it *measured*: a
vendor's own markup, matched against a fixed table. It never rules on what a
page means. That division is deliberate and load-bearing -- six mechanisms that
crossed it have been deleted from this codebase -- and it is why the reading
above is yours to do.

**A `script` reply carries what you returned, and nothing about the page except
a wall.** It used to carry a measurement of the tab you ended on -- a character
count, the picture geometry, the url and title -- and that is gone. Whatever you
want to know about the page, return it: `Page.Url`, `await Page.TitleAsync()`,
`(await Page.InnerTextAsync("body")).Length`. They cost you nothing extra,
because your script is already there.

The consequence is worth stating plainly, because nothing will state it for you:
**a page that reads short will not tell you it was picture-borne**, and no field
in the reply hints at it. See below.

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
such a page reads as *short* rather than as *truncated*. **Nothing in the reply
will tell you this happened.** The reply carries what you returned; if you did
not measure the pictures, nobody did.

`pictures.js` sits in this skill's directory beside `markdown.js`, and reads the
same way -- off disk, since the server runs on your machine:

    var pictures = await File.ReadAllTextAsync("/path/to/skills/using-passenger/pictures.js");
    var seen = await Page.EvaluateAsync<JsonElement>(pictures);
    var largest = seen.GetProperty("largest").GetDouble();
    var src = seen.GetProperty("src").GetString();

Take the fields out rather than returning `seen` itself: Playwright deserialises
with reference handling on, so a `JsonElement` handed straight back carries a
spurious `"$id": "1"` beside the real keys.

It returns `{ largest, count, src }`: the biggest visible picture as a share of
the window, how many clear a tenth of it, and how to reach the biggest one.
Roughly: `0.0` on a docs page, `0.10` on an illustrated article, `0.27` on a
comic, `0.38` on a three-photo note, above `1.0` on a marketing hero. **A large
picture and little text is the case worth acting on** -- so measure the text in
the same script and compare the two yourself.

Then reach the picture:

    // when `src` is a URL -- take the bytes, not the response
    var response = await Page.APIRequest.GetAsync(src);
    var bytes = await response.BodyAsync();

    // when `src` is a CSS selector, which it is for an inline svg or a canvas
    await Page.Locator(src).ScreenshotAsync(new() { Path = path });

**Do not return the response itself.** `Page.APIRequest.GetAsync` hands back an
`IAPIResponse`, which is a live handle -- returning it is refused, and until
this skill was written it was worse than refused: it serialised the driver's
headers and timings and handed them back looking like an answer. Ask it for
`BodyAsync()` or `TextAsync()` and return that.

Three things this measurement gets honestly wrong, all of them quiet:

- **`src` is not always the `<img src>` you saw.** It is `currentSrc` where
  there is one, so a responsive image resolves to the variant *this window*
  loaded -- on xkcd 2347 that is `dependency_2x.png`, not the
  `dependency.png` in the markup. Usually what you want; occasionally not the
  asset you meant to name.
- **A protocol-relative URL needs a scheme.** xkcd serves
  `//imgs.xkcd.com/...`, which `Page.APIRequest.GetAsync` will not take as-is.
- **A small picture can still be the whole content.** An xkcd comic measures
  0.06. This is a number, not a verdict, which is why you are the one holding
  it.

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

## What cannot cross back

A tool result is JSON, and nearly every Playwright call hands back a live
handle that is not. Returning an `ILocator` or an `IElementHandle` is refused
by name with `SCRIPT_RETURN_NOT_JSON` -- return what you wanted *from* it
instead:

    return Page.Url;                                  // not Page
    return await Page.Locator("h1").InnerTextAsync(); // not the locator

## Housekeeping

Three verbs, and the differences between them are deliberate:

    closeTabs(lane, [tab, ...])    the ones you name
    closeAllTabs(lane)             every tab in your lane; the lane survives
    destroyLane(lane)              the tabs, then the lane itself

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

**The screen is shared, and refcounted.** `showBrowser` claims it; the viewer
stays up until every lane that claimed it has called `hideBrowser`. So your
`hideBrowser` cannot take the window away from someone else's human -- and
theirs cannot take it from yours.

**`orphan` is a junk drawer anyone may open.** Tabs a page opened by itself
join the lane that caused them, but a tab a *human* opened during a handoff has
no opener for Chrome to trace, so it lands in `orphan` -- readable and closable
by any caller, and never collected on a timer. `listTabs("orphan")` is how you
look, and looking first is the whole etiquette: somebody may be halfway through
a login in there.

**What lanes do not isolate.** One profile means one Chrome and one attach, and
attaching initialises every open tab. So a tab wedged mid-navigation in *any*
lane slows or fails calls in every lane, and freeing it can stop a navigation
another lane was making. Lanes partition ownership, not availability. When it
happens the tool says which lanes it touched; it cannot prevent it.

`browserStatus` reports `wedged:` for exactly this: `none`, or a count per
kind. Read it when calls have gone slow for no reason you can see -- the tab
doing it is usually not yours, and the count is the only thing that says so.

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
