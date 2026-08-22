---
id: 014
title: Content that lives in pictures reads as an empty page
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

Both extractors return text. `dom` walks the live document and now emits
`[label](url)` for anchors -- but an `<img>` contributes nothing at all,
not its `src`, not its `alt`. trafilatura is called without
`include_images`. So a page whose content is *in* its pictures comes back
looking like a page with no content, and nothing in the result says
otherwise.

Measured on xiaohongshu, logged in, through this tool:

    /explore/6a01c765…  mode=article   305 words
                        body text:     none

That note is a video post. Its title -- the whole question it asks --
survives only in `<title>`; the markdown holds the speed-control widget
("2x 1.5x 1x 0.75x 0.5x 倍速"), an "可能含AI生成内容" badge, and then 10 of
its 36 comments. A caller reading the markdown alone would report that
the note is empty. It is not empty; it is a video.

The 图文 case is the same defect with a worse failure mode, because it
looks plausible. Travel and city-research notes routinely put the price
list, the map, the opening hours, or the timetable *in the photo* and
write "都在图里" as the body. The extraction then returns a short, well-formed,
entirely real paragraph that omits the thing the note is for -- and an
agent summarising it produces a confident answer built on the caption.

This is the last hard blocker under the vault's xiaohongshu research
method, which names "必须读图" as one of six criteria: the other five
degraded gracefully when that recipe moved onto this tool, and this one
did not degrade, it vanished.

Note the shape: the tool cannot currently distinguish *"there is nothing
here"* from *"what is here is not text."* That is a truthfulness problem
before it is a feature request -- an agent has no way to hedge a claim it
cannot see the edge of.

To decide:

1. Whether images become markdown (`![alt](src)`, inline, the way anchors
   did in [A listing read through dom mode has no link
   targets](007-links-lost-in-dom-mode.md)) or a separate manifest on the
   `Fetched` record. Inline preserves position, which matters when a note
   interleaves nine photos with nine captions. A manifest is easier to cap.
2. Whether `alt` is worth having on its own. On xiaohongshu it is
   near-useless (`笔记图片`); on documentation and news sites it often
   carries the caption. If images become inline markdown, an empty `alt`
   is an empty label -- and 007 already had to decide what to do with a
   label-less anchor.
3. What this costs. 007 measured +9x on a listing for links; a page of
   twenty cover images at one long CDN URL each is the same order again,
   against the same unbounded-output concern already in the map's Fog.
   A cap, or `src` only for images above some rendered size, may be the
   difference between useful and unusable.
4. Whether the URLs are even fetchable once emitted. xiaohongshu CDN
   images have historically wanted a `Referer`, and the caller reaching
   them with `curl` is outside the warm session that makes this tool work
   at all -- the same trap as the 403 in [Reaching content that sits
   behind an interaction](004-driving-the-page.md). If the answer is that
   only this tool can retrieve them, that is an argument for a companion
   read rather than a bare URL.
5. Whether a video note should say so. `mode_used` reports how the page
   was read; nothing reports that the page's payload was a `<video>`.
   Cheap to detect, and it converts a silent empty body into a fact the
   caller can report.

## Answer

Closed by [The passthrough tool that runs a script against a page](013-the-passthrough-tool.md),
which landed while this ticket was open and turns out to cover the case
without any of the extraction changes proposed here.

Measured, on a page with a figure:

    page.request.get(src)                 -> 200, 19,981 bytes
    page.locator("figure").screenshot()   -> 135,586 bytes on disk

Both routes work, and the image was then read back and seen. Two things
follow, and they answer four of the five questions above by removing them:

- **Question 4 is answered by measurement, in the good direction.**
  `page.request.get` goes through the browser's own session, so the CDN gets
  the cookies and the `Referer` the warm profile carries. The 403-to-`curl`
  trap that this ticket feared -- the same one 004 hit -- does not apply to a
  caller inside the session. And `locator.screenshot()` needs no URL at all,
  which is the route that cannot be broken by a CDN policy.
- **Questions 1-3 dissolve.** The choice between inline `![alt](src)` and a
  manifest, whether `alt` earns its place, and what a page of twenty CDN URLs
  costs were all questions about what to put in *everyone's* markdown. A
  script asks for exactly what it wants -- a list of srcs, one element's
  screenshot, the `alt` of a single figure -- so there is no cap to design and
  no unbounded output to fear. The right pattern is a file path plus a read,
  never base64 through the return value, which would spend the context this
  saves.

**Deliberately left undone.** Question 5, and with it the truthfulness framing
in the question above: a plain `fetch` of a video note still returns the
speed-control widget and the comments, with nothing saying the payload was a
video, and a 图文 note still returns a well-formed paragraph that omits the
price list in the photo. `script` cures that only for a caller who already
suspects. Closing this ticket is a decision that the cure is enough and the
warning is not worth building now; the risk is recorded in the map's Fog so it
stays visible rather than lost.
