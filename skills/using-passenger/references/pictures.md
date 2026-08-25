# Pages whose content is a picture

What lives in a photograph, a menu board, a chart or a comic was never text, so
such a page reads as *short* rather than as *truncated*. **Nothing in the reply
will tell you this happened.** The reply carries what you returned; if you did
not measure the pictures, nobody did.

## Measure them

`scripts/pictures.js` sits beside `markdown.js`, and reads the same way -- off
disk, since the server runs on your machine:

    const js = await fs.readFile("/path/to/skills/using-passenger/scripts/pictures.js", "utf8");
    const seen = await Page.evaluate(eval(js));   // eval: see reading-a-page.md
    const { largest, src } = seen;

Take the fields out rather than returning `seen` itself: Playwright
deserialises with reference handling on, so a `JsonElement` handed straight
back carries a spurious `"$id": "1"` beside the real keys.

It returns `{ largest, count, src }`: the biggest visible picture as a share of
the window, how many clear a tenth of it, and how to reach the biggest one.
Roughly:

| `largest` | page |
|---|---|
| `0.0` | a docs page |
| `0.10` | an illustrated article |
| `0.27` | a comic |
| `0.38` | a three-photo note |
| above `1.0` | a marketing hero |

**A large picture and little text is the case worth acting on** -- so measure
the text in the same script and compare the two yourself. These are numbers,
not verdicts.

## Reach the picture

    // when `src` is a URL -- take the bytes, not the response
    const response = await Page.request.get(src);
    await fs.writeFile(path, await response.body());   // then read it with your own tools

    // when `src` is a CSS selector, which it is for an inline svg or a canvas
    await Page.locator(src).screenshot({ path });

The file lands on the disk your other tools see, so an image does not have to
cross back as JSON. **Do not return the response itself** -- see
`writing-scripts.md`.

## Three things this gets honestly wrong, all of them quiet

- **`src` is not always the `<img src>` you saw.** It is `currentSrc` where
  there is one, so a responsive image resolves to the variant *this window*
  loaded -- on xkcd 2347 that is `dependency_2x.png`, not the `dependency.png`
  in the markup. Usually what you want; occasionally not the asset you meant to
  name.
- **A protocol-relative URL needs a scheme.** xkcd serves `//imgs.xkcd.com/...`,
  which `Page.request.get` will not take as-is.
- **A small picture can still be the whole content.** An xkcd comic measures
  0.06.

Like `markdown.js`, this is a recipe on disk rather than an API: read it, and
change it when it is measuring the wrong thing.
