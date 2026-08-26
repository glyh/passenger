# Reading a page

The two cheapest reads are in `SKILL.md` and answer most questions. This file
is the rest of the ladder: the page's own JSON, markdown with structure intact,
and the two ways a whole page should not come back to you.

## Just the part you want

```js
return await Page.locator("#results").innerText();

return await Page.$$eval(
    "a[href]", els => els.map(e => ({ text: e.textContent.trim(), href: e.href })));
```

Usually the right answer, and the one that costs least context.

**The second argument is a function, not a string.** Hand `$$eval` or
`evaluate` a string and Playwright evaluates it as an *expression* rather than
calling it, so you get `undefined` and no error. `writing-scripts.md` has the
full shape of that trap, including the one case where a string *is* what you
want.

`innerText("body")` remains the escape hatch for pages that defeat everything
else: 12306's ticket results render through their own templating, and
`innerText` is the only thing that sees them.

## The page's own JSON, without rendering it

A site that draws itself with JavaScript usually ships the same data as JSON in
the HTML it already served — an `__INITIAL_STATE__` or `__NEXT_DATA__` blob — or
names it in a `<link rel=preload>` in the `<head>` that the browser is about to
fetch anyway. `Page.request` reaches either through this Chrome, carrying this
profile's cookies, with no navigation and no rendering:

```js
const response = await Page.request.get(url);
const html = await response.text();
// then the state blob out of `html`, or the preload link's href and one more get
```

**Look for this before writing a single selector.** It is one round trip, it
cannot be defeated by lazy rendering, and what comes back is *structured* — the
fields a listing card omits are usually all sitting in it. The resulting shape
is: fetch, parse, filter, and render only the two or three items that survived.

Two constraints:

- These responses are often hundreds of kilobytes. Write them to disk rather
  than returning them (see below).
- `get` returns a live handle. Ask it for `text()` or `body()` and return that
  (`writing-scripts.md`).

It is also *reading* in the sense **Prefer reading to driving** means: no click,
no keystroke, nothing a behavioural system scores. Use it freely.

### When `Page.request` cannot verify the certificate

`Page.request` does its own TLS verification, stricter than the browsing
context beside it. A host serving an incomplete certificate chain — the leaf
without the intermediate, which every real browser papers over by fetching the
missing link itself — fails here with `unable to verify the first certificate`,
while `Page.goto` to the same origin loads fine.

**That asymmetry is the tell: if navigation works and `Page.request` does not,
suspect the chain, not the site.**

Fix by making the request from inside the page, where the browsing context's own
trust applies:

```js
await Page.goto(origin);               // any page on that origin
const text = await Page.evaluate(async (u) => {
    const r = await fetch(u);
    return await r.text();
}, url);
```

That `fetch` is the *page's*, which is the point: it runs inside the tab, so it
carries the tab's cookies, origin, and certificate exception. You do have a
`fetch` of your own in scope; it has none of those, which is why it is the wrong
one here.

For bytes rather than text — a PDF, an image, a font — return base64 and decode
on this side. **Build the string in chunks:** spreading a whole file into
`String.fromCharCode(...)` passes one argument per byte and throws `RangeError:
Maximum call stack size exceeded` somewhere in the low hundreds of kilobytes,
which is under every PDF worth fetching this way.

```js
const b64 = await Page.evaluate(async (u) => {
    const b = new Uint8Array(await (await fetch(u)).arrayBuffer());
    let s = '';
    for (let i = 0; i < b.length; i += 0x8000)
        s += String.fromCharCode.apply(null, b.subarray(i, i + 0x8000));
    return btoa(s);
}, url);
await fs.writeFile(path, b64, "base64");   // fs decodes on the way out
```

Base64 is four bytes out for every three in, and all of it crosses back through
a tool reply. Check the size first — a large file wants a download, not an
encoding.

This costs a navigation that `Page.request` would have saved, so reach for it
only once the certificate error has appeared. **Same-origin only:** the page's
`fetch` is subject to CORS, which `Page.request` is not.

⚠️ The certificate asymmetry is measured; **these two recipes are written from
it and have not been run verbatim.** Print the length of what comes back and
check it against expectation before building on either.

## Markdown, with headings, lists, fenced code, resolved links

`markdown.js` is in `scripts/`, one directory up from this file. **The server
runs on your machine**, so read it off disk rather than pasting it into the
script:

```js
const js = await fs.readFile("/path/to/skills/using-passenger/scripts/markdown.js", "utf8");
return await Page.evaluate(eval(js));
```

Build the real path from the one you read this file from: these references and
`scripts/` are siblings under the skill directory.

**The `eval` is load-bearing** — the one place a string will not do. The file is
a single arrow-function expression, and `Page.evaluate` handed a *string*
evaluates it as an expression rather than calling it, so the page builds the
function, cannot serialise it, and returns `undefined` with no error. Measured:
the same file passed as a string returns `undefined`; passed through `eval` it
returns 45,389 characters of PEP 8. `eval` turns the text into a function on
this side; Playwright then sends its source to the page, which is what it does
with any function you pass.

**Read the file rather than pasting it**, for a reason sharper than
convenience: a tool call is JSON, and every backslash has to survive that. The
regexes are full of them, and a transcription that doubles some and not others
either fails to parse or — worse — decodes an escape into the character it names
and hands the page something that is no longer JavaScript. The two Unicode line
separators did exactly that, ending a regex literal early with `SyntaxError:
Invalid regular expression: missing /`. They are built with `new RegExp` now, so
that instance is gone; the class is not. A file read never crosses the boundary
at all.

### What it does

Walks the live DOM, keeps only what `checkVisibility()` reports as visible,
resolves every `href` against the document, emits `[label](url)` inline, fences
`pre` blocks, and tidies the result. Takes an optional `[stripSelector,
rootSelectors]` to override where it starts and what it discards. It runs in the
page rather than on the server, which is why the C# port left it untouched, and
the JavaScript one after it.

**It is not always right. Three known failure shapes:**

- It keeps **everything visible under the root it picks**, so on a post with a
  comment thread you get the post and the comments. For the post alone, supply
  your own selector.
- It picks its root from a short candidate list (`main`, `article`,
  `#content`…). On a page whose furniture matches one of those thirty times
  over, it can start in the wrong place.
- It strips a fixed furniture list — `nav`, `header`, `footer`, `aside` — and
  **something carrying content can be on that list.** Unlike the other two, this
  one does not show up in the character count.

### On Sphinx and docutils pages, run `unstrip-asides.js` first

docutils emits footnotes and citations as `<aside class="footnote">` and wraps
groups of them in an outer `aside`, so `markdown.js` discards the reference
apparatus and keeps the prose pointing at it.

```js
const dir = "/path/to/skills/using-passenger/scripts/";
const fix = await fs.readFile(dir + "unstrip-asides.js", "utf8");
const js  = await fs.readFile(dir + "markdown.js", "utf8");
const rescued  = await Page.evaluate(eval(fix));        // 7 on PEP 8
const markdown = await Page.evaluate(eval(js));
```

Measured on PEP 8, so you have both ends to check against: **45,389 characters
without it, 7 asides rescued, 46,122 with.** The page's own `innerText` is
45,407 — markdown comes out *longer* than the text once the reference apparatus
is back and every link is spelled `[label](url)`.

`unstrip-asides.js` retags content-bearing asides as `section` so the strip list
stops matching them, and returns how many it rescued. It is a separate file
because both of `aside`'s jobs are real — on a news site it genuinely is a
sidebar — so this is yours to opt into.

Safe to run anywhere: it rescues nothing and changes nothing where there is
nothing to rescue (0 on theguardian.com's 22 asides), and running it twice
rescues 0 the second time. It mutates the live DOM, which is free on a tab you
opened to read and worth knowing on a tab a human is working in.

### When to use `html-to-markdown` instead

`markdown.js` reads the *live* page: it keeps what `checkVisibility()` reports
visible, so lazily-rendered and JavaScript-drawn content is included, and it
resolves links against the document it is standing in. No converter working on
saved bytes can do that.

What it does not do is boilerplate removal, metadata, or discussions. The
`html-to-markdown` skill does all three on HTML you already have. Once
`Page.content()` or `Page.request` has given you the bytes, prefer it for:

- **A forum, Q&A, or comment thread.** `markdown.js` has one root and keeps
  everything visible under it; that skill detects threads and converts each post
  body separately. That is the difference between keeping the answers and
  keeping only the question.
- **Anything you want frontmatter on** — title, author, date, site — because you
  are filing it rather than reading it once.
- **A page whose furniture defeats the root heuristic.** Its extractor does the
  job the three failure shapes above describe going wrong.

Measured on PEP 8: `markdown.js` gives 45,389 characters and silently drops the
footnotes and `## References`; `html-to-markdown` gives 49,708 with frontmatter
and keeps them. `unstrip-asides.js` closes that particular gap (46,122), which
is the point of that section — but it is one known shape, and the converter did
not have to be told.

**The two are not rivals.** `script` gets you the page; either one turns it into
markdown. Which is right depends on whether the *rendering* mattered.

### It is a recipe, not an API — read it, change it when it is wrong

It is a single arrow-function expression in a file you already have on disk,
deliberately literal so it can be understood in one pass. Nothing versions it or
depends on its internals: nothing on this side calls into it, the reply carries
only what your script returned, and its two overrides cover the common case
rather than every case.

**So when the root heuristic picks a decoy, or the strip list discards the
content, edit the source you just read and evaluate that.** Do it in the string
you pass to `Page.evaluate`, or in your own copy for a site you keep coming back
to. That is best-effort by design, not a contract you are working around.

## A whole page goes to disk, not into the reply

A tool reply is JSON, so a returned page arrives quoted and escaped — every
newline as `\n`, on one line, all of it in your context whether you wanted it or
not. The filesystem is shared, so hand it to yourself as a file:

```js
const js = await fs.readFile("/path/to/skills/using-passenger/scripts/markdown.js", "utf8");
const markdown = await Page.evaluate(eval(js));
const path = "/tmp/pep8.md";            // yours to name; nothing here picks one
await fs.writeFile(path, markdown);
return { path, chars: markdown.length };
```

Now the markdown is text on disk and `chars` is there to check against
expectation. Return the string directly for a short read; write it out for a
long one.
