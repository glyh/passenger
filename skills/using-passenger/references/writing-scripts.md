# Writing the JavaScript

`SKILL.md` has the two that stop a script running at all -- `Page` capitalised,
top-level `return` and `await` both fine. These are the rest, and most of them
are not about the page.

## What you are writing

Your source runs as the body of an async function inside the server's own
process, with the server's own globals in scope. **passenger runs on your
machine**, so there is no sandbox here and none is pretended: `fetch`, `URL`,
`TextEncoder`, `Buffer`, `process`, `structuredClone`, `AbortController`, the
timers -- if node has it, you have it. There is no `window`, because this is
not the page; reach the page through `Page`.

Five names are handed in on top of that:

    Page                    a Playwright Page, and the whole point
    console                 all of it, routed to stderr -- see below
    fs                      node:fs/promises
    path                    node:path
    require                 node's, so `require('node:os')` and friends work

`import` is not available as a statement (you are inside a function, not a
module), but `require` covers the same ground and dynamic `import()` works.

**`fetch` exists but is almost never what you want.** It goes around the
browser -- no cookies, no session, none of the logged-in Chrome this tool
exists for -- so a page that needs any of that will hand it a login screen or a
challenge. `Page.request` is the one to reach for: same API shape, and it goes
through the browser's own context. `fetch` used to be left out of scope to make
that point; it is in scope now, and the point is unchanged.

## The ones that bite once

**`Page.evaluate` takes a function, not a string.** This is the single most
expensive mistake here, because it does not throw. Playwright decides what you
handed it by `typeof`: a function is called in the page, and a *string* is
evaluated as an **expression**. So `Page.evaluate("els => els.length", arg)`
evaluates to a function object, which is not serialisable, and you get
`undefined` back with no error at all. Pass the real thing:

    await Page.evaluate((sel) => document.querySelectorAll(sel).length, "a");

This one cost the tool itself a silent bug: its own wall probe passed its
matcher as a string, measured nothing, and reported every page as clean. If you
are porting a recipe from anywhere that drove Playwright from another language,
this is the line that transfers wrongly -- those bindings *require* a string.

**`console` goes to stderr, all of it.** stdout is the JSON-RPC transport, so
the `console` in scope is rebuilt to write everything -- `log`, `warn`, `table`,
all of it -- to stderr. Trace freely; you will see it in the server's log, not
in your reply. What you want *back* you must `return`.

**Guard every property read on the page side.** `.innerText` on an element that
is not there throws `Cannot read properties of undefined`, and that takes down
the whole script as `SCRIPT_RAISED` -- one missing node and you get nothing
instead of the other nineteen rows. Write `(el || {}).innerText || ''`, or
`el?.innerText ?? ''`.

**Navigating again mid-script destroys the context.** Evaluating after a `goto`
that itself followed an evaluation raises `Execution context was destroyed, most
likely because of a navigation`. Put the `goto` inside the per-item helper and
wait once after it before reading.

**`operationTimeoutSeconds` is a budget per Playwright operation, not per
script.** Omit it and each `goto`, `click` or `waitForSelector` gets
Playwright's own 30s; a script doing thirty scroll rounds is nowhere near that
while a single screenshot of a tall page can be. Raise it on the call that
contains one slow operation, not on the call that contains many quick ones, and
pass 0 for no limit. Nothing bounds your *script* -- a loop that never calls
Playwright runs until the client gives up.

**A missing `tab` does not fail -- it answers.** Omit `tab` and you get a fresh
blank page, and the script runs happily against `about:blank` and returns zeroes
and empty strings indistinguishable from a page with nothing on it. Pass the
`tab` from the previous reply when you are continuing one. The opposite mistake
is loud: a tab that has since been closed throws `TargetClosedError`, and the
fix is to navigate again without it.

**Parse a site's JSON -- do not fish text out of it with a regex.** A site may
write its non-ASCII escaped, and that is normal and valid: Baidu's tieba search
API answers `"title":"Wei：对我..."`, which *is* `Wei：对我...`
spelled the long way. A parser undoes that spelling and a regex does not, so a
script that runs `body.match(/"title":"(.*?)"/g)` and returns the captures hands
back `\uXXXX` verbatim -- and this side will not undo it, because a returned
string is your payload, not something it re-encodes. Parse instead:

    const data = JSON.parse(await response.text());
    const title = data.data.post_list[0].title;

The regex is also lossy in a way that has nothing to do with escaping: `(.*?)`
up to the next quote truncates any field containing an escaped quote, silently,
keeping the half before it. If a captured field comes back with `\uXXXX` in it,
that is the tell -- do not reach for an unescape helper, reach for the parser.

**Parse fetched HTML too -- and know what `innerText` does once you have.** The
cheapest way to run selectors over something `Page.request` fetched is to hand
the string to the page and let it build a real document:

    const html = await (await Page.request.get(url)).text();
    const got = await Page.evaluate((h) => {
      const doc = new DOMParser().parseFromString(h, 'text/html');
      return { title: doc.title, rows: [...doc.querySelectorAll('.row')].map(e => e.textContent.trim()) };
    }, html);

That gives you `querySelector`, decoded entities, and correct container
boundaries, none of which a regex over the raw bytes gets right. Two things
about it bite:

- **A parsed document has no layout, so `innerText` has no line breaks.** It is
  not the `innerText` you get from a rendered page -- it comes back closer to
  `textContent`, one unbroken run. Splitting it on `\n` yields a single
  enormous "line", so every line-oriented filter matches that one line and
  returns the whole page. Measured: a filter meant to pick six rows off a
  listing returned the entire 200 KB document, four times over. Select the
  nodes you want instead of slicing text.
- **A regex over the raw HTML misses any value split across tags.** Markup sits
  between a number and its unit far more often than it looks: one listing page
  contains `元/月` thirty times while `/([\d,]+)\s*元\/月/` matches it zero
  times, because each price is `<em>1900</em> 元/月`. The tell is a unit whose
  occurrence count far exceeds your number-plus-unit hits -- it reads exactly
  like a page with no prices on it.

**A page's own state blob is not always JSON.** `window.__INITIAL_STATE__` and
friends are JavaScript *expressions*, so they can carry `undefined` and
`new Map([])`, which `JSON.parse` refuses. Substitute before parsing rather than
giving up:

    const raw = m[1]
      .replace(/(?<=[:\[,])undefined(?=[,}\]])/g, 'null')
      .replace(/new Map\(\[\]\)/g, '{}');

**Return the value, not JSON of it.** What you return crosses as JSON either
way, so `return results;` hands back an array or an object as itself.
Serialising it first buys nothing and costs the caller a JSON string to unwrap.
Nothing on this path escapes non-ASCII -- CJK and emoji cross as themselves, in
both directions.

## What cannot cross back

A tool result is JSON, so the only things genuinely refused are the ones that
are not a JSON document: a cycle, a BigInt. Those come back as
`SCRIPT_RETURN_NOT_JSON`.

Live Playwright objects are *not* refused, and that is worth knowing because it
looks like a success. Return `Page`, a locator, or an `APIResponse` and you get
Playwright's own identity for it -- small, and labelled:

    return Page;                       // {"_type":"Page","_guid":"page@a5f77e…"}
    return Page.locator('h1');         // {"_apiName":"Locator","_selector":"h1",…}
    return await Page.request.get(u);  // {"_apiName":"APIResponse","_request":{…}}

**`_type` or `_apiName` in your reply means you returned a handle, not an
answer.** Ask it for what you wanted instead:

    return Page.url();
    return await Page.locator('h1').innerText();
    return await (await Page.request.get(u)).text();

## Bytes, and things too big to return

`fs` is `node:fs/promises` and it is the same filesystem you are on -- the
server runs on your machine. So a screenshot, a PDF, or a 200 KB page of
markdown does not have to come back through the reply:

    await fs.writeFile('/tmp/page.md', markdown);
    return { path: '/tmp/page.md', chars: markdown.length };

That is also how a file gets *into* a page. Dragging one onto the viewer window
cannot work -- VNC carries no file transfer -- but the browser shares this
filesystem, so:

    await Page.locator('input[type=file]').setInputFiles('/tmp/x.pdf');

## Do not restructure a script to avoid the parse

Compiling a caller's source is `new vm.Script` -- V8 parsing a string, with no
toolchain behind it. It is far below the noise of a single navigation, so
batching unrelated work into one script to amortise it buys nothing while
costing you the ability to continue from where a failure left off.
