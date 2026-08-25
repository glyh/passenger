# Writing the JavaScript

`SKILL.md` has the two that stop a script running at all -- `Page` capitalised,
top-level `return` and `await` both fine. These are the rest, and most of them
are not about the page.

## What you are writing

Your source runs in a `node:vm` context with a short list of names in scope and
nothing else. There is no `require`, no `import`, no module wrapper, and no
`window`:

    Page                    a Playwright Page, and the whole point
    console                 all of it, routed to stderr -- see below
    fs                      node:fs/promises
    path                    node:path
    setTimeout, clearTimeout

Everything V8 supplies is there: `JSON`, `Math`, `Promise`, `Object`, `Array`,
`Intl`. Everything *Node* adds is not, and the list is longer than it looks --
measured, all `undefined`: `URL`, `URLSearchParams`, `TextEncoder`,
`TextDecoder`, `Buffer`, `atob`, `btoa`, `structuredClone`, `AbortController`,
`process`, `require`. A vm context is a bare V8 realm, so anything you would
call a "Node builtin" has to be reached another way.

Two of those have easy answers. Base64 belongs to `fs`, which decodes on the way
out -- `await fs.writeFile(path, b64, 'base64')` -- and anything you would want
`URL` or `TextEncoder` for, the *page* has, so do it inside a
`Page.evaluate` and return the result.

**`fetch` is absent deliberately**, not as an oversight of the same kind. It
would be a second way onto the web that goes around the browser -- no cookies,
no session, none of what this tool exists for. `Page.request` is the sanctioned
one and it goes through the browser's own context.

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

**`timeoutSeconds` is a budget per Playwright operation, not per script.** It
defaults to 60, so a script doing thirty scroll rounds is nowhere near it while
a single screenshot of a tall page can be. Raise it on the call that contains
one slow operation, not on the call that contains many quick ones.

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
