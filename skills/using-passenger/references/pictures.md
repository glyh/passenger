# Pages whose content is a picture

Content living in a photograph, menu board, chart, or comic was never text, so
such a page reads as *short* rather than *truncated*. **Nothing in the reply
reports this.** The reply carries what you returned; if you did not measure the
pictures, nobody did.

## Measure them

`scripts/pictures.js` sits beside `markdown.js` and reads the same way — off
disk, since the server runs on your machine:

```js
const js = await fs.readFile("/path/to/skills/using-passenger/scripts/pictures.js", "utf8");
const seen = await Page.evaluate(eval(js));   // eval: see reading-a-page.md
```

It returns `{ largest, count, src }`: the largest visible picture as a share of
the window, how many clear a tenth of it, and how to reach the largest.

Return `seen` whole if you want it whole. (A warning stood here about a spurious
`"$id": "1"` appearing beside the real keys. That was `System.Text.Json`'s
reference handling, from before the port, and it is not true on this runtime.
Measured: an object returned straight out of `Page.evaluate` comes back with
exactly the keys it had.)

## Reading `largest`

**`largest` is picture area ÷ viewport area, so it scales with the window.**
The same page measures differently at a different window size, and values above
`1.0` are normal for a picture larger than the window.

| `largest` | Page |
| --- | --- |
| `0.0` | a docs page |
| `0.10` | an illustrated article |
| `0.27` | a comic |
| `0.38` | a three-photo note |
| above `1.0` | a marketing hero |

Treat these as orientation, not thresholds. Measured on xkcd 2347: `0.106` with
`count: 1` against 1,168 characters of text — a page that is entirely a picture,
sitting at the "illustrated article" row.

**Large picture plus little text is the case to act on**, so measure the text in
the same script and compare them yourself:

```js
return { ...seen, textLen: (await Page.innerText("body")).length };
```

These are numbers, not verdicts.

## Reach the picture

```js
// when `src` is a URL -- take the bytes, not the response
const response = await Page.request.get(src);
await fs.writeFile(path, await response.body());   // then read it with your own tools

// when `src` is a CSS selector, which it is for an inline svg or a canvas
await Page.locator(src).screenshot({ path });
```

The file lands on the disk your other tools see, so an image never has to cross
back as JSON. **Do not return the response itself** — see `writing-scripts.md`.

## Two things this gets honestly wrong, both quiet

- **`src` is not always the `<img src>` you saw.** It is `currentSrc` where
  there is one, so a responsive image resolves to the variant *this window*
  loaded — on xkcd 2347 that is `dependency_2x.png`, not the `dependency.png` in
  the markup. Usually what you want; occasionally not the asset you meant to
  name. (`currentSrc` is an absolute URL by spec, so a protocol-relative `//host/…`
  in the markup arrives resolved. Measured: xkcd's markup is protocol-relative
  and `src` came back `https://imgs.xkcd.com/comics/dependency_2x.png`.)
- **A small picture can still be the whole content.** xkcd 2347 measures 0.106
  and is nothing but the comic.

Like `markdown.js`, this is a recipe on disk rather than an API: read it, and
change it when it is measuring the wrong thing.
