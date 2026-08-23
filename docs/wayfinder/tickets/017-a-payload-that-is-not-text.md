---
id: 017
title: A payload that is not text
labels: [wayfinder:grilling]
status: open
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
