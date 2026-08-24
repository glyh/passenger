---
id: 048
title: Move the picture measurement to the caller
labels: [wayfinder:grilling]
status: open
assignee:
blocked_by: []
---

## Question

Every `script` reply carries a `Measured` envelope the caller did not ask for:
`url`, `title`, `char_count`, `largest_image`, `large_images`,
`largest_image_src`. Taking it costs a websocket round trip for the title, one
for `innerText`, and one to evaluate `pictures.js` -- on every call, whether the
caller wanted any of it or not.

The proposal is to delete that envelope from the MCP surface and ship
`pictures.js` to the `using-passenger` skill beside `walker.js`, so a caller
that wants the picture geometry pastes it into a script and evaluates it, the
same way it already does to read a page.

**The case for.** [The layer stays thin](020-how-thin-can-this-layer-get.md) is
the standing principle, and [delete fetch](047-one-door-script.md) already
applied it to the harder half: extraction left the codebase, `read` stopped
being bound in a script's scope, and the walker became a recipe. `pictures.js`
is the last piece of JavaScript this side still runs on the caller's behalf,
and the last thing in a reply the caller did not ask for. If reading a page is
the caller's, measuring its pictures is too -- and there is no seam to keep,
because `script` already hands over `page`.

**The case against, which is [content that lives in
pictures](014-content-that-lives-in-pictures.md) and
[017](017-a-payload-that-is-not-text.md).** The whole argument for measuring
pictures was that this is the one thing a caller *cannot* recover from the
result it was handed. A photograph was never in the text, so a page whose price
list is an image reads as *short* rather than as *truncated* -- and a caller
that has to know to ask has already failed to notice. An unasked-for number is
how the tool says something the caller had no way to see. That is a different
shape from the walker, which answers a question the caller knew it had.

To decide:

1. **Whether the envelope goes whole or in part.** `char_count` and
   `largest_image` are not the same claim. The character count is
   `document.body.innerText` and near-free; the pictures cost a script
   evaluation. A defensible middle is to keep the count and drop the geometry,
   and the question is whether that middle is principled or merely cheaper.

2. **Whether a caller who does not know to ask is this side's problem.**
   [019](019-the-tool-does-not-learn.md) says the tool remembers nothing about a
   site and that recall is the agent's; [the tool measures, the caller
   judges](020-how-thin-can-this-layer-get.md) says measurement is this side's.
   An unprompted measurement sits exactly on that seam. Deciding this decides
   the ticket.

3. **What the skill has to say instead.** If the number stops arriving, the
   skill's "Pictures are not in the text" section changes from *read
   `largest_image` against `char_count`* to *run this when a page reads short*
   -- which is advice about noticing, and the skill's record on advice about
   noticing is mixed: the soft-wall section is the one thing there that most
   often goes unread.

4. **What it costs to keep `pictures.js` shipping in two places, or in none.**
   Today it is embedded in the assembly and never handed out. Moving it to the
   skill makes it a recipe like `walker.js`; keeping both would be two copies
   of one measurement, which is the drift [026](026-one-description-two-doors.md)
   is about.

5. **Whether this is priced against the C# port.** The port is underway and
   `pictures.js` is embedded in the assembly with a comment explaining why it is
   not in the skill. If this ticket lands, that comment and the embedded
   resource both come back out -- so it is cheaper to decide before the port's
   MCP surface is finished than after.

## Decision 5 has expired; the rest stands

*Recorded 2026-08-24.* The port landed and
[the Python door is deleted](053-delete-the-python-door.md), so the "cheaper to
decide before the port's MCP surface is finished" pricing in decision 5 is spent.
It was not decided before, and the thing it warned about is now the actual cost:
`pictures.js` is an embedded resource at `src/Passenger/Assets/pictures.js`,
loaded by `src/Passenger/PicturesJs.cs`, and moving it to the skill means taking
the embed and its comment back out.

Everything else is unchanged and still live. The envelope is built on every
`script` reply at `src/Passenger/Service.cs:242` -- a `TitleAsync`, an
`InnerTextAsync("body")` and a `PicturesJs.MeasureAsync`, three round trips,
whether or not the caller wanted any of them. Decisions 1 through 4 are as
written.

Two small corrections to the Question. The fields are camelCase now, not snake:
`url`, `title`, `charCount`, `largestImage`, `largeImages`, `largestImageSrc`
(`Service.cs:266-274`). And decision 4's "two places" is cheaper than it was --
there is one skill, so shipping `pictures.js` beside `walker.js` is one copy, not
two.

One thing the skill eval added that bears on decision 3. `largestImageSrc` can
name a different asset than the `<img src>` a reader sees -- on xkcd 2347 it
points at the retina variant -- so if the geometry moves to the caller, the
recipe has to say that where today nothing does. It is an argument for moving it:
a number the caller computes is a number the caller can see the definition of.
