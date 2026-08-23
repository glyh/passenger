---
id: 022
title: Drop ICU
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: [021]
---

## Question

PyICU comes out. This is decided, not open -- what is open is what
`word_count` becomes on the way.

The ruler arrived in [Word counts assume spaces, so CJK pages read as
empty](008-word-counts-assume-spaces.md) because two things *decided*
with it: `classify` compared a page's words against `min_words`, and
`choose` compared the two extractions against a yield floor. A
`len(text.split())` ruler read a 1,890-character Chinese note as one
word, so both decided wrongly, in the direction of believing the page
empty.

Both consumers are gone. `classify` lost its word-count tier in [The
extract mode decides whether a page counts as
blocked](005-mode-decides-blocked.md); `choose` goes in [Remove auto
mode](021-remove-auto-mode.md). Nothing left decides anything with a word
count, so a dictionary-based segmenter is being carried for a number
reported to the caller for information.

That number is not free. PyICU is this project's only native dependency
-- it is why the Python side moved to nix at all, since it was otherwise
compiling against the host's libicu, which moves twice a year and takes
the extension with it.

This is not 008 being reversed. 008 was right about the consumers it had;
they simply do not exist any more.

Out: `pyicu` from `pyproject.toml` dependencies and from `flake.nix`
`pythonDeps`, the `icu.*` mypy override, `import icu` and the
`BreakIterator` in `ab/text.py`, and whatever of `tests/test_text.py`
tests segmentation rather than the module that replaces it. `unlinked`
exists only for measuring and follows whatever is decided below.

To decide:

1. **What replaces `word_count`.** Keeping the name and computing it with
   `split()` is the one thing that must not happen -- that is the 008 bug
   restored, and now silent, since nothing would misbehave visibly to
   catch it. Real options:
   - **Rename to a character count.** `len(text)` is script-independent,
     needs no dependency, and is arguably more useful to an agent than
     words, since context is spent in tokens and tokens track characters
     more closely than they track words across scripts. Costs an output
     contract change and a rename in both doors.
   - **Drop the field.** The caller has the markdown and can measure
     whatever it likes. This is the thin-layer answer, and consistent
     with [The result says what it did not
     reach](016-the-result-says-what-it-missed.md) -- do not compute for
     the caller what the caller can see.
   - **Keep words, without ICU.** Only defensible if some cheap
     approximation is honest across scripts, and the measurement in 008
     suggests none is.
2. Whether `handoff` still wants to print `resolved (N words)` when a
   human clears a challenge, and in what unit. It is the one remaining
   place the count is spoken aloud rather than returned.
3. Whether `nix/python-overlay.nix` shrinks as a result, and whether
   anything else in the flake existed only to make the native build work.

The recommendation is the character count under an honest name: the
number has a real use for a caller sizing a page against its context
budget, and dropping it outright removes something already relied on for
no gain beyond tidiness.

## Answer

**PyICU is out, and `word_count` became `char_count`: `len(text)`, link
markup included.** The output contract at both doors is now

    {"type": "fetched", "url": ..., "title": ..., "mode_used": ...,
     "char_count": 113, "markdown": ...}

`ab/text.py` and `tests/test_text.py` are deleted outright rather than
rewritten -- with `count_words` and `unlinked` both gone the module held
nothing, and a one-line `len()` on the model it belongs to does not need a
shared ruler. Also out: `pyicu` from `pyproject.toml` and `flake.nix`, the
`icu.*` mypy override.

### Question 1: a character count, under a name that says so

The recommendation stood. `len(text)` is script-independent, needs no
dependency, and answers the only question a caller has about the number:
how much of its context this will cost. Tokens track characters far more
closely than they track words across scripts -- the fixture that drove 008
makes the case in one line. The zh.wikipedia article on 长隆海洋王国 comes
back as 9,713 characters and as 331 `split()` "words". The character
number is right in both scripts without a dictionary behind it.

Dropping the field was the close second, and lost on 016's own terms: 016
says do not compute for the caller what the caller can see, but it also
says the result should *say* what it did not reach. A size the caller can
read before deciding whether to spend the markdown on its context is the
useful half of that, and it is already paid for.

`len(text.split())` under the old name was the forbidden option and stayed
forbidden. Everything the module docstring knew about why is carried into
`Extraction.char_count`, since that is now the only place the mistake could
be made again.

### Question 1a: link targets are counted now

`unlinked` went with ICU, and not merely because nothing needs it. Its
reason was that a nav bar's worth of hrefs must not stand in for content
when `choose` compared two extractions -- a comparison that no longer
exists. What the number means now is *the size of the markdown the caller
is holding*, and that markdown has the URLs in it. Stripping them would
make the tool under-report its own output.

### Question 2: `handoff` says characters

`resolved (113 characters)`, the same unit as the field, so the line a
human reads after clearing a challenge and the number the agent gets back
cannot disagree.

### Question 3: the flake does not shrink, and should not

`nix/python-overlay.nix` is untouched: `pyicu` came from nixpkgs directly,
not from an override, so there was nothing there to delete. The comment
above the interpreter now says six dependencies rather than seven, and two
of them are still overridden.

Nothing else in the flake existed only for the native build, and the flake
does not become optional now that the native dependency is gone. It was
prompted by PyICU but it is what pins *everything* -- chromium for the
walker test, the noVNC tree, the compositor on the wrapper's PATH -- and
the alternative it replaced resolved the Python side from the host at first
use. The pin is the point, not a leftover of the native build.

`icu4c` is still in the built closure, via `patchright` → `nodejs`. That is
nixpkgs' own pinned copy, linked by node, not a Python extension of ours
compiled against whatever libicu the host happened to ship -- which was the
whole failure mode. Nothing this project builds links against it.

### Also removed: `uv.lock`

Found while editing `pyproject.toml`, which was the only thing that would
have kept it current. `uv` stopped being the build path in 7f50c99 when the
Python side moved to nix; the lockfile outlived it as a second dependency
record that nothing reads and that can silently disagree with
`pythonDeps`. The flake is the record.

### What was verified

`nix flake check` green (33 tests, down 9 with `tests/test_text.py`),
`mypy --strict` clean over 21 files, `nix build` produces a closure with no
PyICU in it, and the built binary exercised live: `fetch
https://example.com --mode article --json` returns `char_count: 113`, and
the Chinese Wikipedia article above returns 9,713.
