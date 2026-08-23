---
id: 045
title: Build drop_run: a caller-named repeated run, dropped from a dom read
labels: [wayfinder:task]
status: open
assignee:
blocked_by: [043]
---

## Question


The work decided by [Whether article's last job can be done
structurally](044-articles-last-job-structurally.md). **That ticket holds the
design and the reasons; this one does not restate them.** Read its *Settled by
grilling* section before starting -- every choice below was argued there and
several of them are counter-intuitive on their own.

**Blocked on [043](043-tidy-hides-walker-differences.md)** deliberately. This
change alters what the walker emits, and 043 is the finding that the walker
suite cannot see part of its own output: an F# reimplementation passed 13/13
while dropping a trailing space on every text node, because `tidy()` normalises
the difference away before any assertion sees it. Verifying a change to the
walker with a suite that has a known hole in it is how
[034](034-broken-walker-passes-its-tests.md) happened. 043 is small; this is the
reason to do it first rather than eventually.

## What to build

1. **Run detection in the walker.** For each container, group children by
   `tagName` plus the sequence of their own children's tag names -- **ignoring
   classes**, which is not optional: WordPress alternates `even`/`odd` and
   `thread-even`/`thread-odd`, and a class-aware signature counted
   moonofalabama's hundred comments as forty-one.
2. **A run inventory in the result.** Per run: the selector that identifies it,
   `siblings`, `chars`, `share`, and `first` -- roughly 80 characters of the
   first member, quoted from the page. The sample is what lets a caller tell a
   comment thread from a related-stories rail without a second fetch.
3. **`min_siblings`, caller-set, default 2.** Definitional, not tuned. The
   count of runs printed is capped as presentation and the result says how many
   were not listed.
4. **A body-less read on `fetch`**, as `script` already has (`read_page`), so
   the inventory costs almost no context.
5. **`drop_run`, taking a selector**, re-resolved against the fresh DOM because
   the probe and the drop are two page loads. The result reports how many
   siblings were actually dropped, which may not be the number the probe saw.
6. **Refuse `drop_run` with `mode=article`.** Not ignore. A silently ignored
   flag is [039](039-extractor-returns-nothing-on-12306.md)'s skeleton wearing a
   parameter -- it looks like it worked.

`article` is not touched. `dom` without the flag is not touched.

## Acceptance

[The acceptance set](../assets/044-acceptance-set.md), five pages with URLs and
the diagnostic each carries. Two of them are the tests that matter:

- **moonofalabama** -- 100 comment siblings, 55,745 characters, beside a
  5,572-character post. `drop_run` on the comment selector should leave roughly
  the post, with `dom`'s links and visibility filtering intact.
- **americanthinker** -- a 263-sibling teaser grid. It must appear in the
  inventory and must **not** be dropped. This is the case that would have been a
  silent failure under an automatic strip, and it is the standing guard against
  drifting back toward one.

## To decide while building

1. **Where the inventory lives in the models.** `Fetched` gains a field, and
   `models.py` parses at every boundary -- so a `Run` model rather than a dict,
   like every other structure this codebase passes downstream.
2. **The CLI door.** [026](026-one-description-two-doors.md) is about these two
   surfaces drifting, and this adds three parameters to the MCP door. Mirroring
   them by hand is the symptom 026 names; not mirroring them widens the gap.
   Decide deliberately and say which was chosen.
3. **Whether the walker change is written twice.** It lands in `walker.js`
   today. [030](030-the-walker-reads-a-snapshot.md) closed on that string being
   the one part of `extract.py` a port inherits unchanged -- and Fable has since
   been measured as a way to write it in F# and still run it in the page (see
   [the port measurements](../assets/023-port-measurements-findings.md)). Not
   blocking: JavaScript now is inherited either way.

## What this enables

The measurement [044](044-articles-last-job-structurally.md) recorded as
trafilatura's deletion trigger and could not run without the flag: does
`dom` + `drop_run` match `article` on boilerplate removal across the five pages?
025 already found `article` *losing* on four axes `dom` wins -- pagination
links, labels, hidden overlays, listings. If boilerplate is the only remaining
edge and it goes, `article` is deletable, trafilatura leaves, and
[023](023-rewriting-into-csharp.md)'s expensive half disappears with it.
