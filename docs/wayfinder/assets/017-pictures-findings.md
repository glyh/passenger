# 017: what a page's pictures measure, and which metric survives

Measured 2026-08-23 against the live session, viewport 1784x993. Every row is
one `goto` at `fetch`'s own timing -- `domcontentloaded` plus a 1500ms settle
-- so the numbers are what the tool would actually report, not what a patient
reader would see.

Four candidate metrics, computed side by side on the same navigation:

    largest   biggest visible picture box, over the viewport's area
    count>=5  how many boxes clear 5% of the viewport
    count>=10 how many clear 10%
    sum       total picture area, in viewports

## The finding the metric rests on

A xiaohongshu **explore listing** and a xiaohongshu **图文 note**, read the
same way, minutes apart:

| Page | chars | largest | count>=5 | count>=10 | sum |
|---|---|---|---|---|---|
| explore listing (30 thumbnails) | 1,693 | **0.06** | 30 | 0 | **1.72** |
| 图文 note (3 photos) | 1,989 | **0.38** | 3 | 3 | **1.16** |

The listing has *more* total picture area than the photo note and ten times
the count. Every metric except `largest` calls a thumbnail grid the more
picture-borne of the two, which is backwards: the listing's content is its
text and its links, and the note's content is its photographs. A count and a
sum both answer "how much picture is on this page"; only the largest box
answers "is any one picture big enough to be the point".

`count>=10` survives as a second field because at that bar it stops
contradicting: the listing reads 0 and the note reads 3. At 5% it reads 30 and
5 on the two pages whose ratio says text.

## The acceptance set

| Page | chars | largest | count>=10 | biggest box |
|---|---|---|---|---|
| apod.nasa.gov | 1,944 | **0.29** | 1 | `IFRAME` vimeo |
| xkcd 2000 | 1,178 | **0.27** | 1 | `IMG` comic |
| xiaohongshu 图文 note | 1,989 | **0.38** | 3 | `IMG` 720x929 |
| xiaohongshu video note | 1,895 | **0.37** | 1 | `VIDEO` 697x929 |
| ourworldindata grapher | 8,904 | **0.21** | 1 | `svg` chart |
| apple.com/macbook-pro | 56,188 | **1.92** | 28 | `IMG` hero |
| cnn.com | 7,227 | 0.29 | 4 | `IMG` lead photo |
| bbc.com/news | 7,360 | 0.22 | 8 | `IMG` lead photo |
| wikipedia (Photosynthesis) | 86,863 | 0.10 | 0 | `IMG` diagram |
| moonofalabama | 41,068 | 0.05 | 0 | `IMG` |
| xiaohongshu explore | 1,693 | 0.06 | 0 | `IMG` thumbnail |
| news.ycombinator.com | 3,903 | 0.0002 | 0 | `IMG` favicon |
| docs.python.org asyncio | 46,255 | 0.0001 | 0 | `IMG` favicon |

The ticket predicted "a count with no natural threshold". For a count that is
true. For the largest box it is not: the pages whose content is a picture
measure 0.21 to 1.92, and the pages whose content is text measure 0 to 0.10,
with nothing in between. That gap is a factor of two wide across thirteen
pages, and it is the reason this ticket built something where 014 and 016 did
not.

Note that a front page -- cnn at 0.29, bbc at 0.22 -- sits with the positives.
That is not a false positive so much as a true statement about a modern news
front page, whose lead story really is carried by a photograph.

## What counts as a picture

Five tags, each chosen because it was the biggest box on some page in the set,
and each measured for what excluding it costs:

| Tag | The page it was chosen for | Reads without it |
|---|---|---|
| `IMG` | xiaohongshu 图文 note, 0.38 | -- |
| `VIDEO` | xiaohongshu video note, 0.37 | 0.004 |
| `svg` | ourworldindata grapher, 0.21 | 0.003 |
| `CANVAS` | stripe.com/blog, 0.63 | 0.16 |
| `IFRAME` | apod.nasa.gov, 0.29 | **0.00** |

APOD is the case that settles `IFRAME`. The Astronomy Picture of the Day, the
most literally picture-borne page on the web, measured **0.00** -- that day's
picture was a Vimeo embed. It also has a principled answer: `walker.js` lists
IFRAME in its `OPAQUE` set, so an iframe's content is not in the markdown
either, which makes it precisely a payload that is not text.

CSS `background-image` was measured and left out. It found one large
background across the set (a xiaohongshu note), and costs a
`querySelectorAll('*')` plus a `getComputedStyle` per element on every fetch
-- 364 background-image elements on one wikipedia page alone.

## The rule that was nearly taken and is wrong

The ticket's first instinct, and the one this session started from, was
"pictures the browser actually renders **on top**" -- intersecting the
viewport, and hit by `elementFromPoint` at their centre. Measured:

| Page | large pictures | ...that are on screen and topmost |
|---|---|---|
| apple.com/macbook-pro | 30 | **1** |
| xiaohongshu 图文 note | 3 | **2** |
| moonofalabama | 1 | **0** |

It does not measure *rendered*, it measures *above the fold*. `fetch` is
goto-settle-read and never scrolls, so a page whose one photograph sits below
the first screen would report no picture at all. This is ticket 035's
asymmetry exactly -- furniture surviving is a cost, content vanishing is a lie
-- so eligibility is `checkVisibility({visibilityProperty: true})` and a
non-zero box, wherever it sits. That also keeps this measurement and the text
walk agreeing about what is on the page.

## Two costs, taken knowingly

**A consent wall is an iframe.** theguardian.com/international measures
**0.99** -- a full-window `sourcepoint.theguardian.com` cookie dialog. The
false positive is real and was accepted rather than filtered: same-origin-only
would exclude the Vimeo embed that is APOD, and a vendor list is the learned
signature table ticket 019 deleted. The caller can see
`sourcepoint.theguardian.com` in `largest_image_src` and judge, which is the
division of labour this whole area settled on.

**A small picture can be the whole content.** xkcd 2001's comic is 308x360 =
**0.06**, indistinguishable from a thumbnail, though the comic *is* the page.
Viewport-relative geometry cannot see this; what the caller has instead is
`char_count` on the same record -- 1,202 there against 46,255 on the python
docs page. A large picture and little text is the case worth acting on, and
combining the two is left to the caller.

## A timing artifact worth knowing about

The first sweep measured xkcd 2000's comic at **0.03** and the second at
**0.27**. The difference was a cold cache: at `domcontentloaded` plus 1500ms
the image had not arrived, and an unloaded `<img>` with no width/height
attributes has a zero-height box. Re-measured with `Network.setCacheDisabled`,
pages whose images carry explicit dimensions or are lazy-loaded with a
placeholder are unaffected, and pages like xkcd that let the image size the
box can under-report on a first, cold visit. Not fixed: waiting for `load`
would change what every fetch costs to correct a number that is advisory. It
is why `tests/test_pictures.py` uses data URIs with pinned dimensions rather
than real image fetches.

## Verdict

Three fields on `Fetched`: `largest_image` (the ratio), `large_images` (count
at 10% of the viewport), `largest_image_src` (a URL, or a CSS selector when
the biggest box is an `svg`, a `canvas`, or a lazy loader's `data:`
placeholder -- apple.com's 2359x1443 hero reported its src as a 1x1 base64
gif). No threshold, no verdict, no bucket word: the caller gets the
measurement and decides, and `script` is how it reaches the picture.
