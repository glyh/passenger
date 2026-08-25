# Reading a page

The two cheapest reads are in `SKILL.md` and answer most questions. This file
is the rest of the ladder: the page's own JSON, markdown with structure intact,
and the two ways a whole page should not come back to you.

## Just the part you want

    return await Page.Locator("#results").InnerTextAsync();

    return await Page.EvalOnSelectorAllAsync<string[]>(
        "a[href]", "els => els.map(e => e.textContent.trim() + ' -> ' + e.href)");

Usually the right answer, and the one that costs least context. **The type
argument on `EvalOnSelectorAllAsync<T>` is required** -- see
`writing-scripts.md`, along with why several fields per element want to be
`JSON.stringify`d strings rather than objects.

`InnerTextAsync("body")` stays the escape hatch for pages that defeat
everything else: 12306's ticket results render through their own templating and
`InnerText` is the only thing that sees them.

## The page's own JSON, without rendering it

A site that draws itself with JavaScript usually ships the same data as JSON in
the HTML it already served -- a `__INITIAL_STATE__` or `__NEXT_DATA__` blob --
or names it in a `<link rel=preload>` in the `<head>` that the browser is about
to fetch anyway. `Page.APIRequest` reaches either through this Chrome, carrying
this profile's cookies, with no navigation and no rendering:

    var response = await Page.APIRequest.GetAsync(url);
    var html = await response.TextAsync();
    // then the state blob out of `html`, or the preload link's href and one more GetAsync

Worth looking for before you write a single selector. It is one round trip, it
cannot be defeated by lazy rendering, and what comes back is *structured* --
the fields a listing card leaves out are usually all sitting in it. The shape
that falls out of this is fetch, parse, filter, and render only the two or
three items that survived.

Two things to know: these responses are often hundreds of kilobytes, so write
them to disk rather than returning them (below); and `GetAsync` hands back a
live handle, so ask it for `TextAsync()` or `BodyAsync()` and return that
(`writing-scripts.md`).

### When `APIRequest` cannot verify the certificate

`Page.APIRequest` does its own TLS verification, and it is stricter than the
browsing context beside it. A host that serves an incomplete certificate chain
-- the leaf without the intermediate, which every real browser papers over by
fetching the missing link itself -- fails here with `unable to verify the first
certificate`, while `Page.GotoAsync` to the same origin loads fine.

That asymmetry is the tell: **if navigation works and `APIRequest` does not,
suspect the chain, not the site.** The fix is to make the request from inside
the page, where the browsing context's own trust applies:

    await Page.GotoAsync(origin);          // any page on that origin
    var text = await Page.EvaluateAsync<string>(@"async (u) => {
        const r = await fetch(u);
        return await r.text();
    }", url);

For bytes rather than text -- a PDF, an image, a font -- come back base64 and
decode on this side. **Build the string in chunks:** spreading a whole file
into `String.fromCharCode(...)` passes one argument per byte and throws
`RangeError: Maximum call stack size exceeded` somewhere in the low hundreds of
kilobytes, which is under every PDF worth fetching this way.

    var b64 = await Page.EvaluateAsync<string>(@"async (u) => {
        const b = new Uint8Array(await (await fetch(u)).arrayBuffer());
        let s = '';
        for (let i = 0; i < b.length; i += 0x8000)
            s += String.fromCharCode.apply(null, b.subarray(i, i + 0x8000));
        return btoa(s);
    }", url);
    await File.WriteAllBytesAsync(path, Convert.FromBase64String(b64));

Base64 is four bytes out for every three in, and all of it crosses back through
a tool reply, so check the size before you reach for this -- a large file wants
a download, not an encoding.

This costs a navigation that `APIRequest` would have saved, so reach for it
only once the certificate error has actually appeared. Same-origin only: the
page's `fetch` is subject to CORS, which `APIRequest` is not.

⚠️ The certificate asymmetry is measured; **these two recipes are written from
it and have not been run verbatim.** Print the length of what comes back and
read it against what you expected before you build on either.

It is also *reading*, in the sense **Prefer reading to driving** means: no
click, no keystroke, nothing a behavioural system scores. Use it freely.

## Markdown, with headings, lists, fenced code and resolved links

`markdown.js` sits in `scripts/`, one directory up from this file. **The server
runs on your machine, in your filesystem**, so read it off disk rather than
pasting it into the script:

    var js = await File.ReadAllTextAsync("/path/to/skills/using-passenger/scripts/markdown.js");
    return await Page.EvaluateAsync<string>(js);

Use the real path, built from the one you read this file from: these references
and `scripts/` are siblings under the skill directory. Reading beats pasting for a reason sharper than convenience: a
tool call is JSON, and every backslash in the file has to survive that. The
regexes are full of them, and a transcription that doubles some and not others
either fails to parse or -- worse -- decodes an escape into the character it
names and hands the page something that is no longer JavaScript. The two
Unicode line separators used to do exactly that, ending a regex literal early
with `SyntaxError: Invalid regular expression: missing /`; they are built with
`new RegExp` now, so that particular one is gone, but the class is not. A file
read never crosses the boundary at all.

It walks the live DOM, keeps only what `checkVisibility()` says is visible,
resolves every `href` against the document, emits `[label](url)` inline, fences
`pre` blocks, and tidies the result. It takes an optional
`[stripSelector, rootSelectors]` if you want to override where it starts or
what it discards. It runs in the page rather than on the server, which is why
the C# port left it untouched.

It is not magic and it is not always right. Three known shapes:

- It keeps **everything visible under the root it picks**, so on a post with a
  comment thread you get the post and the comments. If you want the post alone,
  say so in your own selector.
- It picks its root from a short list of candidates (`main`, `article`,
  `#content`…). On a page whose furniture matches one of those thirty times
  over, it can start in the wrong place.
- It strips a fixed list of furniture -- `nav`, `header`, `footer`, `aside` --
  and **something carrying content can be on that list**. Unlike the other two,
  this one does not show up in the character count.

### On Sphinx and docutils pages, run `unstrip-asides.js` first

docutils emits footnotes and citations as `<aside class="footnote">` and wraps
groups of them in an outer `aside`, so `markdown.js` discards the reference
apparatus and keeps the prose that points at it. Measured on PEP 8: 45,389
characters against the page's own 45,407 -- an eighteen-character shortfall for
losing every footnote and the whole `## References` section, which is exactly
the number you were told to read against expectation.

`unstrip-asides.js` sits beside `markdown.js` in `scripts/`, retags the content-bearing
asides as `section` so the strip list stops matching them, and returns how many
it rescued:

    var fix = await File.ReadAllTextAsync("/path/to/skills/using-passenger/scripts/unstrip-asides.js");
    var js  = await File.ReadAllTextAsync("/path/to/skills/using-passenger/scripts/markdown.js");
    var rescued  = await Page.EvaluateAsync<int>(fix);      // 7 on PEP 8
    var markdown = await Page.EvaluateAsync<string>(js);

It is a separate file because both of `aside`'s jobs are real -- on a news site
it genuinely is a sidebar -- so this is yours to opt into where it is not. Run
it anywhere: it rescues nothing and changes nothing where there is nothing to
rescue (0 on theguardian.com's 22 asides), and running it twice rescues 0 the
second time. It mutates the live DOM, which is free on a tab you opened to read
and worth knowing about on a tab a human is working in.

### It is a recipe, not an API -- read it, and change it when it is wrong

It is a single arrow-function expression in a file you already have on disk,
deliberately literal so it can be understood in one pass. Nothing versions it
or depends on its internals: no C# calls into it, the reply carries only what
your script returned, and the two overrides it takes cover the common case
rather than every case. So when the root heuristic picks a decoy, or the strip
list discards what was carrying the content, editing the source you just read
and evaluating *that* is a normal thing to do -- in the string you pass to
`EvaluateAsync`, or in your own copy for a site you keep coming back to. That
is best-effort by design, not a contract you are working around.

## A whole page goes to disk, not into the reply

A tool reply is JSON, so a returned page arrives quoted and escaped -- every
newline as `\n`, on one line, and all of it in your context whether you wanted
it or not. The filesystem is shared, so hand it to yourself as a file:

    var js = await File.ReadAllTextAsync("/path/to/skills/using-passenger/scripts/markdown.js");
    var markdown = await Page.EvaluateAsync<string>(js);
    var path = "/tmp/pep8.md";              // yours to name; nothing here picks one
    await File.WriteAllTextAsync(path, markdown);
    return new Dictionary<string, object> { ["path"] = path, ["chars"] = markdown.Length };

Now the markdown is text on disk, and `chars` is there to read against what you
expected. Return the string directly for a short read; write it out for a long
one.
