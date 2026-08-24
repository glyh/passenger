---
id: 051
title: The walker strips aside, and aside carries footnotes
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

`walker.js:20` puts `aside` in `DEFAULT_STRIP`, beside `nav`, `header`, `footer`
and the ARIA landmark roles:

    'script, style, noscript, template, svg, nav, header, footer, aside, ' +

Every other name on that line is furniture. `aside` is not — HTML gives it to
tangentially related content, and **docutils and Sphinx emit footnotes as
`<aside class="footnote">`**. So on any Sphinx-rendered page the walker returns
the prose and silently drops the footnotes and the reference list that the prose
points at.

Measured on `https://peps.python.org/pep-0008/` during a skill eval:

| | stock walker | `aside` removed from the strip list |
|---|---|---|
| chars returned | 45,389 | recovers footnote 1 and references [2]–[5] |
| absolute links | 20 | 23 |
| `## References` | present, **empty** | populated |

The page's own `char_count` was 45,407. **An 18-character shortfall** — 0.04% —
against a body that lost its entire reference apparatus. That is the number the
skills tell a caller to read against expectation, and here it was in front of
them and could not have flagged this.

This is not a PEP 8 quirk. It is every page docutils or Sphinx renders, which is
a large share of the technical documentation this tool is pointed at.

### Why it is not just "delete `aside` from the list"

The name is doing two jobs and only one of them is wrong. `aside` genuinely is a
sidebar on a news site or a blog — pull quotes, related-links rails, promo boxes
— and that is presumably why it was added. Dropping it wholesale trades a silent
loss on documentation for a silent gain of furniture everywhere else, and the
second is the failure [028](028-the-root-heuristic-picks-a-decoy.md) and
[044](044-articles-last-job-structurally.md) were about.

Options, none obviously right:

1. **Strip `aside` except where it is marked as content** — `aside.footnote`,
   `aside[role=doc-footnote]`, `aside[role=doc-endnote]`. Narrow, targeted at the
   known emitters, and the DPUB-ARIA roles are the standard's own answer to
   "this aside is not furniture". Costs a special case in a list that is
   otherwise uniform.
2. **Drop `aside` from `DEFAULT_STRIP` entirely** and let the root heuristic and
   `checkVisibility()` do the work. Simplest, and consistent with the walker
   keeping everything visible under its root. Untested against a news page.
3. **Leave the code and document the flag.** The walker already takes
   `[stripSelector, rootSelectors]`, and the eval agent recovered the footnotes
   with it unaided once it noticed the empty heading. But it only noticed
   because it went looking; the whole problem is that nothing points at the
   loss.

### What this says about the skills

Both skills list the walker's known failure shapes — it keeps everything under
the root it picks, and it can pick the wrong root. This is a third shape they do
not name: **it strips a semantic element that was carrying content**, and unlike
the other two the damage is invisible in the character count. Whatever is
decided here, that shape probably belongs in the "It is not magic" paragraph in
both files.

Note the coupling: `walker.js` is byte-identical across
`skills/using-passenger/` and `skills/using-passenger-csharp/` and
[049](049-skill-for-the-csharp-door.md) requires it stay that way, so a fix is
two files plus `tests/test_walker.py`. 049's *Owed* section flagged exactly this
— "`walker.js` now exists twice and must stay byte-identical, with nothing but a
comment in each enforcing it" — and this is the first change that has to honour
it.

*Struck 2026-08-24.* [Delete the Python door](053-delete-the-python-door.md)
deleted the second skill and the Python suite. `walker.js` exists once, at
`skills/using-passenger/walker.js`, and there is nothing left to keep it
identical *to*; `tests/test_walker.py` is gone and `tests/Passenger.Tests/` has
no walker tests at all, so a fix is **one file and no test**. That is worse
rather than better: the defect below was found by an eval, and nothing in the
build would notice it coming back. See
[043](043-tidy-hides-walker-differences.md), which is now about that absence.

Nothing else here has moved. `walker.js:20` still strips `aside`, the three
options stand as written, and the paragraph they should feed -- that the walker
can strip a semantic element carrying content, invisibly to the character count
-- now belongs in one "It is not magic" section rather than two.

### How it was found

A twelve-run skill eval (three tasks × {Python, C#} doors × {skill, no skill}),
logging every `script` call and its error code. Tasks 0 and 1 — fetch an image's
bytes, extract HN's front page as JSON — discriminated nothing: all runs
finished in one or two calls with zero errors and near-identical output, with or
without a skill. This was the only task where anything went wrong, and what went
wrong was in the shared recipe rather than in either skill's prose. Recorded
alongside the routing bug in
[050](050-csharp-door-names-the-python-skill.md).

*Renamed 2026-08-24.* `skills/using-passenger/walker.js` is now
`skills/using-passenger/markdown.js`. Every `walker.js` above means that
file; the line numbers are unchanged apart from its header comment, which
was rewritten in the same commit. The traversal is still called a walk.

## Answer

*Closed 2026-08-24.* None of the three options as written. The defect is real
and reproduces exactly as measured, but options 1 and 2 both answer it inside
`markdown.js`, and the ticket's own objection to that stands: `aside` is doing
two jobs, both of them legitimate, and a strip list is one global answer to a
question that has two. What shipped instead is a fourth option the ticket did
not list -- **a separate opt-in pre-pass**, `skills/using-passenger/unstrip-asides.js`.

It runs in the page before `markdown.js`, on the same tab. It finds every
`aside` that is a footnote, endnote, citation or bibliography by class or by
DPUB-ARIA role -- **or that contains one** -- and replaces it with a `section`
holding the same children and the same attributes. The strip list then simply
does not match it. Nothing is extracted and nothing is returned but a count;
the markdown still comes from `markdown.js` and is still the whole page.

The contains-one half is not defensive coding. docutils wraps groups of
footnotes in an outer `aside` that carries no role, and the walk skips an entire
subtree at the outermost `aside` it meets, so rescuing the inner ones alone
achieves nothing. Found empirically on PEP 8 (`2 x aside.footnote-list.brackets`
containing `5 x aside.footnote.brackets[role=doc-footnote]`) and confirmed
afterwards in the docutils release notes, below.

### Measured

| page | asides | rescued | before | after |
|---|---|---|---|---|
| peps.python.org/pep-0008 | 7 | 7 | 45,389 | **46,122** |
| theguardian.com/international | 22 | 0 | 706 | 706 |
| numpy.org (Sphinx, `numpy.mean`) | 1 | 0 | 4,729 | 4,729 |
| en.wikipedia.org/wiki/Footnote | 0 | 0 | 32,170 | 32,170 |
| docs.python.org/3/library/re.html | 0 | 0 | 65,979 | 65,979 |

On PEP 8 the recovered output is **byte-identical** to running `markdown.js`
with `aside` removed from its strip list -- so the pre-pass costs nothing in
fidelity against option 2 while leaving option 2's furniture problem untaken.
Absolute links 20 -> 23, and `## References` goes from present-and-empty to
populated, both as the ticket recorded. A second run rescues 0, so it is
idempotent. The Guardian's 22 asides are the case options 1 and 2 were weighed
against, and none of them is touched.

One measurement artefact worth recording so nobody re-chases it: Wikipedia
returns 32,170 twice and then 32,182 twice with no pre-pass involved and zero
asides on the page. That is the page adding something late, not this script --
and a small illustration of *a read is one screen*.

### The references, since they were asked for

- **docutils RELEASE-NOTES, 0.18** -- "HTML5: Use the semantic tag `<aside>` for
  footnote text and citations, topics (except abstract and toc), admonitions,
  and system messages. Use `<nav>` for the Table of Contents." The change that
  created this.
- **docutils RELEASE-NOTES, 0.19 (2022-07-05)** -- "HTML5: Wrap groups of
  footnotes in an `<aside>` for easier styling. The CSS rule
  `.footnote-list { display: contents; }` can be used to restore the behaviour
  of custom CSS styles." The outer wrapper, from the source.
- **Digital Publishing WAI-ARIA 1.0**, <https://www.w3.org/TR/dpub-aria-1.0/>,
  examples 5 and 24, both literally `<aside id="fn01" role="doc-footnote">`. The
  role half of the selector is the standard's own markup, and it draws the
  distinction the selector relies on: `doc-footnote` is an individual note in
  the body, `doc-endnotes` a collection at the end of a section.
- **HTML Standard 4.3.5** -- an `aside` is "content that is tangentially
  related... often represented as sidebars in printed typography", with
  advertising and groups of `nav` named as uses. Stripping `aside` by default is
  correct, which is the case for opting in rather than editing the list.

### What else changed

The third failure shape this ticket asked for is now in the skill's *It is not
magic* list: it strips a fixed list of furniture and something carrying content
can be on that list, and unlike the other two shapes the character count does
not show it. The Sphinx case and the recipe are written out beside it, and the
frontmatter description names `unstrip-asides.js` so it is visible at routing
time.

The new file has **no backslashes and no non-ASCII at all**, so it is paste-safe
by construction in the sense [052](052-walker-escapes-do-not-survive-transport.md)
could not make `markdown.js`.

### Owed

Still no test, so all of the above was verified by running it against real pages
rather than by anything in the build -- same gap as 052, and still
[043](043-tidy-hides-walker-differences.md).

One wart found on the way and left alone: `markdown.js` guards `args || []` for
a null *argument list*, but its second element is destructured with a default,
which only fires on `undefined`. So `EvaluateAsync(js, new object[] { strip, null })`
throws `roots is not iterable`, and an override of the strip list alone has to
retype the root list too. Not this ticket; noted for whoever touches that line.
