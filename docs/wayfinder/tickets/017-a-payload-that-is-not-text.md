---
id: 017
title: A payload that is not text
labels: [wayfinder:grilling]
status: closed
assignee: glyh
blocked_by: []
---

## Question

Graduated from the map's Fog. It was first written as the second half of
[The result says what it did not reach](016-the-result-says-what-it-missed.md),
inheriting a channel from it -- but 016 was closed unbuilt, and this
question is *stronger* without it rather than orphaned.

The reason is the test that closed 016. There the tool knew nothing the
caller did not: the markers saying content was withheld were sitting in
the markdown the caller already held. Here that is not true. The caller
receives text. A photograph is not in it, was never in it, and no amount
of reading the result will reveal that the price list was in the picture.
This is the one place in this area where the tool holds something the
caller structurally cannot see.

So the question is whether it should say so. A plain `fetch` cannot distinguish "there is nothing
here" from "what is here is not words": a video note returns its player
furniture and its comments, and a 图文 note returns a real paragraph that
omits the price list living in the photograph. `script` is the cure --
[Content that lives in pictures reads as an empty
page](014-content-that-lives-in-pictures.md) measured it -- but only for
a caller who already suspects, and nothing tells them to.

The asymmetry with 015 is the whole of it. Deferred content announces
itself, in text we hand over. A photograph announces nothing. So the
evidence cannot be quoted, only *counted* off the page -- images, videos,
their sizes -- which is a measurement rather than a quotation, and one
with no natural threshold. Every page has images.

That cuts both ways and is why this is a grilling rather than a task.
Privileged information is a reason to speak; a count with no threshold is
a reason to expect the speaking to be noise.

To decide:

1. What would actually be counted, and against what. A bare image count
   is noise on every page ever made; images that are large, or that sit
   inside the extraction's own root, may not be.
2. Whether `mode_used` admitting itself is the cheaper half -- a note that
   the article extractor kept 40 words off a page whose main element is a
   carousel says more than an image count would.
3. Whether the answer is "nothing at all". 014 closed by deciding the
   cure was enough and the warning was not worth building, and 016 has
   since closed unbuilt on a related question -- so the burden here is to
   show why this one is different. The argument that it is: 014 and 016
   both concerned things the caller could reach or read for itself, and
   this does not.

## Answer

**Yes, and the measurement is geometry, not a count.** `Fetched` grows three
fields -- `largest_image`, `large_images`, `largest_image_src` -- reported on
every successful read at both doors. Findings, thirteen pages and four
candidate metrics: [017 pictures](../assets/017-pictures-findings.md).

The ticket's own premise was wrong in the way that mattered. It expected "a
count with no natural threshold", and for a count that holds -- but the
*largest visible picture as a share of the viewport* splits the set cleanly:
pages whose content is a picture measure 0.21 to 1.92, pages whose content is
text measure 0 to 0.10, and nothing lands between. The case that proves it is
two xiaohongshu pages read minutes apart. The explore listing carries 30
thumbnails, 1.72 viewports of picture in total; the 图文 note carries three
photographs, 1.16. Both a count and a summed area call the listing the more
picture-borne of the two, which is backwards. Only the largest box gets it
right: 0.06 against 0.38.

That is also why this ticket built something where 014 and 016 did not. Their
subject was reachable or readable by the caller already. This one is not: the
caller receives text, and no reading of it reveals that the price list was in
the photograph.

What counts as a picture is `img, video, svg, canvas, iframe`, each tag chosen
because it was the biggest box on some page and each measured for the cost of
excluding it. `IFRAME` settles itself: apod.nasa.gov -- the Astronomy Picture
of the Day -- measured **0.00** without it, that day's picture being a Vimeo
embed, and `walker.js` already lists IFRAME as opaque, so an iframe's content
is not in the markdown either. CSS `background-image` was measured and refused:
one large background across the set, against a `querySelectorAll('*')` and a
`getComputedStyle` per element on every fetch.

The instinct this session started from was refused on measurement. "Pictures
the browser renders *on top*" -- viewport-intersecting and hit by
`elementFromPoint` -- does not measure rendered, it measures above the fold,
and `fetch` never scrolls: apple.com fell from 30 large pictures to 1 and
moonofalabama's photograph to 0. Ticket 035's asymmetry, restated -- furniture
surviving is a cost, content vanishing is a lie -- so eligibility is
`checkVisibility({visibilityProperty: true})` and a non-zero box, wherever it
sits, which is also the rule the text walk uses.

Nothing here rules. There is no bucket word, no `images: "dominant"`, and no
floor under which the src is suppressed -- 005 removed a tier that blocked a
page for having fewer words than a threshold and 021 removed a mode that
picked an extractor by comparing two, both of them this side ruling on a
number it hands over anyway. The caller has `largest_image`, `large_images`,
`char_count` and the markdown, and is better placed than a constant here to
say what 0.38 on a 1,989-character page means. `largest_image_src` is a URL
where one exists and a CSS selector otherwise, because two of the five tags
have no URL at all and a lazy loader parks a `data:` placeholder in the third
-- apple.com's 2359x1443 hero reported its src as a 1x1 base64 gif. Both forms
are directly usable: `page.request.get(url)` and
`page.locator(sel).screenshot()`, which is the pair 014 measured.

Two costs taken knowingly, both recorded in the findings. A full-window cookie
consent iframe reads 0.99 on theguardian, and filtering it would need either
same-origin-only -- which excludes APOD -- or the vendor list 019 deleted; the
caller can read `sourcepoint.theguardian.com` in the src and judge. And a
small picture can be the whole content: xkcd 2001's comic is 0.06,
indistinguishable from a thumbnail, and `char_count` on the same record is
what separates it from a listing.

`ab/pictures.js` and `ab/pictures.py`, alongside the walker rather than inside
it -- the walk runs only in `dom` mode, and a document read as `article` is
the case with the strongest claim here. It is measured in `service._fetched`,
which every successful read passes through, so the handoff path and a script's
ending page get it without a second call site. Eleven tests in
`tests/test_pictures.py`, all of which run in a real browser because what is
under test is layout; replacing `pictures.js` with a syntax error fails ten of
them, and the one that survives asserts zeros for a wedged renderer, by design.
