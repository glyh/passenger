---
id: 009
title: Whether defuddle belongs alongside trafilatura as an extract mode
labels: [wayfinder:research]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

`extract.py` has exactly two strategies, and the README is candid that
neither is settled: `article` (trafilatura) has won on every page
measured, and `dom` "is an escape hatch, not a validated fix." The two
open extraction tickets are both symptoms of having only these two --
[A listing read through dom mode has no link
targets](007-links-lost-in-dom-mode.md) is the mode that sees a JS app
throwing away its hrefs, and [The extract mode decides whether a page
counts as blocked](005-mode-decides-blocked.md) is trafilatura's silence
on a JS app being read as a challenge.

Defuddle is the extractor behind Obsidian Web Clipper. It is worth
considering here because of what it is *shaped* like, not because it is
better boilerplate removal:

- It works on a DOM, not on a fetched document. Its natural home is
  inside the page -- which is the one thing trafilatura structurally
  cannot do and the entire reason `dom` exists.
- Its markdown keeps links, tables, and headings. That is the pointer
  half of 007, on a listing that only the live DOM can see.

The CLI is already installed here (`defuddle parse <source> --md`, and
`<source>` may be an HTML *file*, not only a URL). That matters: handing
it `page.content()` from the warm, logged-in Chrome keeps the fetch on
this tool's own path. Letting it take a URL would have it open its own
unauthenticated connection and defeat the point of the project.

To decide:

1. Which of the two integrations is meant. A subprocess over
   `page.content()` is a few lines and reuses the installed CLI, but it
   sees only the serialised HTML -- the same input trafilatura gets, so
   it may inherit the same blind spot on a JS app. Injecting the bundled
   library into the live page over `evaluate` is what the Web Clipper
   actually does and is the version that could subsume `dom`, at the
   cost of vendoring a JS bundle into a Python project.
2. Whether it is a third mode or a replacement. A third value makes
   `choose` a three-way decision on evidence that does not yet exist;
   the README's measurement table is the honest precedent -- measure
   first on the pages already tabulated, then decide, rather than
   shipping an option nobody can choose between. Note that the ruler
   itself is under question: [Word counts assume spaces, so CJK pages
   read as empty](008-word-counts-assume-spaces.md) shows `choose`
   comparing noise to noise on exactly the listing this mode is meant
   to help, so a three-way decision built on the current measure would
   inherit that.
3. What it costs the shells. trafilatura is a Python import; defuddle is
   Node. `flake.nix` currently has no `nodejs`, and the CLI is installed
   through a global npm prefix outside the flake. Adopting it means
   either declaring that dependency properly or accepting a mode that
   fails on a clean checkout.
4. What happens when it is absent or fails. A mode that silently returns
   empty text feeds the same low-word-count path that 005 and 008 both
   show turning into a false `blocked` verdict and a bad block
   proposal -- an unwired Node dependency would fail that way, quietly.
5. Whether `mode_used` still tells the truth. It is currently a closed
   enum in `models.py` that a caller can read back; a fourth value is a
   boundary shape change, not just an internal branch.

Cheap seams, if [What the test suite covers, and how the shells get
tested](001-testing-the-shells.md) lands first: a file-in/markdown-out
extractor is pure by construction and can be measured against fixtures
of the same pages the README already tabulates -- no browser needed for
the comparison that decides point 2.

## Answer

No. Measured, then dropped.

Six pages were dumped as `page.content()` through this tool's own warm
Chrome and fed to both extractors -- same bytes in, so the comparison is
only between the extractors:

| page | trafilatura w / links / fences | defuddle w / links / fences |
|---|---|---|
| xiaohongshu search | 60 / 22 / — | 95 / 67 / — |
| Wikipedia | 11236 / 1283 / — | 11884 / 651 / — |
| react.dev tutorial | 9731 / 11 / 108 | 10385 / 26 / 140 |
| Python docs | 6037 / 227 / 16 | 6507 / 139 / 68 |
| Hacker News front page | 793 / 181 / — | 848 / 17 / — |

Two things fell out that settle the question and correct the premises
this ticket was written on.

**`page.content()` is already the rendered DOM.** trafilatura is handed
the serialised live DOM, not the server's HTML. So it does not fail on a
JS app for want of seeing it -- it sees the same nodes an in-page
injection would, and discards them as boilerplate. Point 1's choice
between a subprocess and a vendored bundle was therefore a choice about
almost nothing: shadow roots aside, both get the same input.

**defuddle does not fix the listing case.** On the xiaohongshu search
page it kept 20 cover-image links with their `xsec_token` intact and
dropped all 22 `class="title"` anchors, text and all -- links without
labels, where `dom` gives labels without links. Hacker News is the same
story at 181 links down to 17. It is a readability-family article
extractor like trafilatura and strips listing furniture for the same
reasons. [A listing read through dom mode has no link
targets](007-links-lost-in-dom-mode.md) stays open and is not helped by
this.

The one real gain was fenced code blocks on documentation: 16 to 68 on
the Python docs, 108 to 140 on the React tutorial. Everything else is a
wash or a regression, and the regressions are in links -- the thing 007
is about.

Against that: defuddle is in nixpkgs (0.19.2, present in the pinned
rev), so `flake.nix` would only have needed the word. But it is Node,
and it is ~19 MB of `node_modules` and a 0.5-0.8s subprocess per fetch
against trafilatura's 0.06-0.15s in-process -- for better code fences on
one page shape. Not worth the closure.

If code-block fidelity on documentation ever becomes the complaint, this
is the measurement to start from rather than a fresh survey.
