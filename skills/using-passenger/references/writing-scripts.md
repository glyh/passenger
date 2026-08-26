# Writing the JavaScript

`SKILL.md` covers the two rules that stop a script running at all: `Page` is
capitalised, and top-level `return` and `await` both work. These are the rest.
Most are not about the page.

## Scope

Your source runs as the body of an async function inside the server's own
process, with that process's globals in scope. **passenger runs on your
machine**, so there is no sandbox and none is pretended: `fetch`, `URL`,
`TextEncoder`, `Buffer`, `process`, `structuredClone`, `AbortController`, the
timers — if node has it, you have it. There is no `window`; this is not the
page. Reach the page through `Page`.

Five names are supplied on top of that:

| Name | Is |
| --- | --- |
| `Page` | a Playwright `Page`, the whole point |
| `console` | all methods, routed to stderr — see below |
| `fs` | `node:fs/promises` |
| `path` | `node:path` |
| `require` | node's, so `require('node:os')` works |

**`require` is the only way to load a module.** `import` is unavailable as a
statement (you are inside a function, not a module), and dynamic `import()`
throws `A dynamic import callback was not specified` — the script runs in a vm
context, which has no module loader attached. `require` covers the same ground:

```js
const os = require("node:os");
```

**`fetch` exists but is almost never what you want.** It goes around the
browser — no cookies, no session, none of the logged-in Chrome this tool exists
for — so a page needing any of that hands it a login screen or a challenge. Use
`Page.request`: same API shape, routed through the browser's own context.

## Traps

### `Page.evaluate` takes a function, not a string

**The single most expensive mistake here, because it does not throw.**
Playwright dispatches on `typeof`: a function is called in the page, a *string*
is evaluated as an **expression**. So `Page.evaluate("els => els.length", arg)`
evaluates to a function object, which is not serialisable, and you get
`undefined` back with no error.

```js
await Page.evaluate((sel) => document.querySelectorAll(sel).length, "a");
```

This cost the tool itself a silent bug: its own wall probe passed its matcher
as a string, measured nothing, and reported every page as clean. **If you are
porting a recipe that drove Playwright from another language, this is the line
that transfers wrongly** — those bindings *require* a string.

The one exception is `eval(js)` on a recipe file read off disk; see
`reading-a-page.md`.

### `console` goes to stderr, all of it

stdout is the JSON-RPC transport, so the `console` in scope is rebuilt to send
every method — `log`, `warn`, `table` — to stderr. Trace freely; output lands
in the server's log, not in your reply. **What you want back, you must
`return`.**

### Guard every property read on the page side

`.innerText` on an element that is not there throws `Cannot read properties of
undefined`, which fails the whole script as `SCRIPT_RAISED`. One missing node
costs you the other nineteen rows. Write `el?.innerText ?? ''`.

### Navigating again mid-script destroys the context

Evaluating after a `goto` that itself followed an evaluation raises `Execution
context was destroyed, most likely because of a navigation`. Put the `goto`
inside the per-item helper and wait once after it before reading.

### `operationTimeoutSeconds` is per Playwright operation, not per script

Omit it and each `goto`, `click`, or `waitForSelector` gets Playwright's own
30s. A script doing thirty scroll rounds is nowhere near that, while a single
screenshot of a tall page can exceed it. Raise it on the call containing one
slow operation, not on the call containing many quick ones. Pass `0` for no
limit.

**Nothing bounds your script.** A loop that never calls Playwright runs until
the client gives up.

### A missing `tab` does not fail — it answers

Omit `tab` and you get a fresh blank page. The script runs happily against
`about:blank` and returns zeroes and empty strings indistinguishable from a
page with nothing on it. Pass the `tab` from the previous reply when continuing.

The opposite mistake is loud: a closed tab throws `TargetClosedError`, and the
fix is to navigate again without it.

## Parsing

### Parse a site's JSON; do not regex text out of it

A site may write its non-ASCII escaped, which is normal and valid: Baidu's
tieba search API answers `"title":"Wei：对我..."`, which *is*
`Wei：对我...` spelled the long way. A parser undoes that spelling; a regex does
not. A script running `body.match(/"title":"(.*?)"/g)` returns `\uXXXX`
verbatim, and this side will not undo it — a returned string is your payload,
not something it re-encodes.

```js
const data = JSON.parse(await response.text());
const title = data.data.post_list[0].title;
```

The regex is also lossy independently of escaping: `(.*?)` up to the next quote
silently truncates any field containing an escaped quote, keeping the half
before it.

**Tell:** a captured field containing `\uXXXX`. Reach for the parser, not an
unescape helper.

### Parse fetched HTML too

The cheapest way to run selectors over something `Page.request` fetched is to
hand the string to the page and let it build a real document:

```js
const html = await (await Page.request.get(url)).text();
const got = await Page.evaluate((h) => {
  const doc = new DOMParser().parseFromString(h, 'text/html');
  return { title: doc.title, rows: [...doc.querySelectorAll('.row')].map(e => e.textContent.trim()) };
}, html);
```

That gives you `querySelector`, decoded entities, and correct container
boundaries — none of which a regex over raw bytes gets right. Two things bite:

- **A parsed document has no layout, so `innerText` has no line breaks.** It is
  not the `innerText` of a rendered page; it comes back closer to `textContent`,
  one unbroken run. Splitting on `\n` yields a single enormous "line", so every
  line-oriented filter matches it and returns the whole page. Measured: a filter
  meant to pick six rows off a listing returned the entire 200 KB document, four
  times over. **Select the nodes you want instead of slicing text.**
- **A regex over raw HTML misses any value split across tags.** Markup sits
  between a number and its unit more often than it looks: one listing page
  contains `元/月` thirty times while `/([\d,]+)\s*元\/月/` matches zero times,
  because each price is `<em>1900</em> 元/月`. **Tell:** a unit whose occurrence
  count far exceeds your number-plus-unit hits. It reads exactly like a page
  with no prices on it.

### A page's own state blob is not always JSON

`window.__INITIAL_STATE__` and friends are JavaScript *expressions*, so they can
carry `undefined` and `new Map([])`, which `JSON.parse` refuses. Substitute
before parsing rather than giving up:

```js
const raw = m[1]
  .replace(/(?<=[:\[,])undefined(?=[,}\]])/g, 'null')
  .replace(/new Map\(\[\]\)/g, '{}');
```

### Return the value, not JSON of it

What you return crosses as JSON either way, so `return results;` hands back an
array or object as itself. Serialising first buys nothing and costs the caller a
JSON string to unwrap. Nothing on this path escapes non-ASCII: CJK and emoji
cross as themselves, in both directions.

## What cannot cross back

A tool result is JSON, so the only things genuinely refused are non-JSON
documents: a cycle, a BigInt. Those return `SCRIPT_RETURN_NOT_JSON`.

**Live Playwright objects are not refused, which matters because it looks like
success.** Return `Page`, a locator, or an `APIResponse` and you get
Playwright's own identity for it — small, and labelled:

```js
return Page;                       // {"_type":"Page","_guid":"page@a5f77e…"}
return Page.locator('h1');         // {"_apiName":"Locator","_selector":"h1",…}
return await Page.request.get(u);  // {"_apiName":"APIResponse","_request":{…}}
```

**`_type` or `_apiName` in your reply means you returned a handle, not an
answer.** Ask it for what you wanted:

```js
return Page.url();
return await Page.locator('h1').innerText();
return await (await Page.request.get(u)).text();
```

## Bytes, and values too large to return

`fs` is `node:fs/promises` on the same filesystem you are on. A screenshot, a
PDF, or a 200 KB page of markdown does not have to come back through the reply:

```js
await fs.writeFile('/tmp/page.md', markdown);
return { path: '/tmp/page.md', chars: markdown.length };
```

That is also how a file gets *into* a page. Dragging one onto the viewer window
cannot work — VNC carries no file transfer — but the browser shares this
filesystem:

```js
await Page.locator('input[type=file]').setInputFiles('/tmp/x.pdf');
```

## Do not batch scripts to amortise compilation

Compiling a caller's source is `new vm.Script` — V8 parsing a string, with no
toolchain behind it. It is far below the noise of a single navigation.
Batching unrelated work into one script to amortise it buys nothing and costs
you the ability to resume from where a failure left off.
