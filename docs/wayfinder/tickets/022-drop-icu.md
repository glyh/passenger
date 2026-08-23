---
id: 022
title: Drop ICU
labels: [wayfinder:task]
status: open
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
