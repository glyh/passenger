---
id: 055
title: Delete the Measured envelope, and ship pictures.js to the skill
labels: [wayfinder:task]
status: open
assignee: lyh (via Claude)
blocked_by: []
---

## Question

Settled by grilling in [048](048-pictures-on-demand.md); this is the build.
Nothing here is open -- if a decision looks arguable, it was argued there and
the reasoning is in that Answer, not repeated in this one.

## What lands

**1. Delete `Measured`.** `src/Passenger/Service.cs:40-61` and the
`[JsonDerivedType(typeof(Measured), "measured")]` line above it.
`Service.MeasureAsync` (`:242`) goes with it, and with it three round trips per
`script` call -- a `TitleAsync`, an `InnerTextAsync("body")` and the
`pictures.js` evaluate.

**2. `PageOutcome` becomes `Blocked` or `Unchecked`.** A new empty record with
the discriminator `"unchecked"`, returned when the caller turned the check off.
`page` is never null: a wall, no wall, or *I did not look*, following 042's rule
that an untested negative must not be indistinguishable from a tested one.

**3. `checkWall`, default true, at both doors.** `script` on the MCP surface
takes it beside `timeoutS`; `passenger script` takes `--no-check-wall`.
`Service.LookAsync` (`:223`) returns `Unchecked` without probing when it is off.
Its docstring currently argues the opposite ("nobody needs to opt out of
those") and has to say the new reason instead.

**4. `pictures.js` moves to `skills/using-passenger/pictures.js`.** Out of
`Passenger.csproj:34`, out of `src/Passenger/Assets/`, and `PicturesJs.cs` is
deleted. Two things travel with it:

- `BigEnough = 0.10` becomes the default *inside* the file, exactly as
  `walker.js:18` holds `DEFAULT_STRIP` and `DEFAULT_ROOTS` -- and its
  justification comment (`PicturesJs.cs:26-33`: why 10% and not 5%, measured on
  a xiaohongshu listing and a wikipedia article) moves with the number.
- The file's header comment still describes `fetch` handing over text and a
  threshold living in `pictures.py`. Both are two deletions out of date.

`Webserve.cs:27` borrows `PicturesJs.ReadResource` for `viewer.html`; the helper
moves into `Webserve`, its only remaining caller.

**5. The CLI loses its measurement line.** `Program.cs:347-351` prints
`N chars on URL` to stderr. It goes rather than being recomputed CLI-side, which
is 046's trade taken again: symmetry over a human's convenience, rather than a
second measurement path and the drift [026](026-one-description-two-doors.md) is
about.

**6. The skill gains the recipe and loses the promise.** `SKILL.md:168-172`
says every reply carries `charCount`, the picture geometry and the url and
title. It does not any more. `SKILL.md:226-251` becomes a recipe that reads
`pictures.js` off disk the way the walker recipe does, and picks up the one
thing the skill eval found and nothing states: `largestImageSrc` can name a
different asset than the `<img src>` a reader sees -- on xkcd 2347 it points at
the retina variant. The "tool measures, you judge" paragraph above it keeps its
first half and loses its examples, since a character count and a fraction of the
viewport are no longer among the things this side reports.

**7. The map's Notes.** *The tool measures; the skill judges* lists "a fraction
of the viewport, a character count, a vendor's own markup" as what this side
reports. Only the third survives.

## Not in scope

The wall check itself stays here, and the vendor table stays a fixed fact this
side owns. `showBrowser(until="unblocked")` is untouched -- it polls the same
table and is the reason the table cannot move. Both were considered in 048 and
both were kept.


## Coupling with 054

[054](054-script-return-should-be-json.md) rewrites the same record. It wants
`Ran`'s `returned` unwrapped; this ticket deletes a `page` variant and adds
another. Both edit `Ran`'s shape, its doc comment, and the `script`
`[Description]` that documents the reply -- so whichever lands second rewrites
the other's paragraph.

They do not conflict in substance. 054 is about where the *script's own* value
sits; this is about what the tool adds beside it. Worth noting that this ticket
makes 054's option 3 weaker: with `Measured` gone, the sibling keys a fused
object could collide with are down to `type`, `tab` and `page`.
