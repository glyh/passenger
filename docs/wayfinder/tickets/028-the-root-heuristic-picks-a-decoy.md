---
id: 028
title: The root heuristic picks a decoy
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

Split out of [Whether dom alone is enough](025-whether-dom-alone-is-enough.md),
where it was measured. This is a live bug in `dom` mode today, and it is
independent of that ticket, of [Remove auto mode](021-remove-auto-mode.md) and
of [Whether this moves to C#](023-rewriting-into-csharp.md).

`_ROOTS` is six selectors tried in order, and the first element over 40
characters wins:

    _ROOTS = ("main", "[role=main]", "article", "#content", "#main", "body")

On americanthinker.com that is a sidebar teaser card. The page carries **30
`<article>` elements**, every one a promo card of 79-196 characters;
`document.querySelector('article')` returns the first, its 164 characters
clear the guard, and `dom` returns **273 characters** -- the card advertising
the very article that was asked for. The 5,769-character piece is never
reached. `article` mode reads the page correctly, so nothing is wrong with the
extraction; the walker was pointed at the wrong element.

It is hidden today, and only by accident. `auto` measures `dom` at 11 words,
under `_MIN_COMPARABLE_WORDS` (40), so `choose` discards it and returns
`article`. That floor is the only thing between a caller and this failure, and
it goes away with 021 -- which is why 021 is blocked on this rather than the
other way round. A caller who passes `mode="dom"` explicitly gets the 273
characters right now.

To decide:

1. **The rule.** Taking the largest candidate rather than the first is the
   obvious one: query every selector in `_ROOTS`, keep the element with the
   most text. On americanthinker that is the real container; on the three
   body-fallthrough pages measured in 025 it changes nothing.
2. **Whether `article` needs a rule of its own.** A document holding thirty
   `<article>` elements is a listing of cards, not an article, and the tag is
   evidence of nothing in that case. Distrusting the selector entirely when
   the page holds many may be simpler and more honest than out-measuring them.
3. **What the 40-character guard is for now.** It was the whole test and
   becomes a floor under a comparison. Whether it survives at all is worth
   asking rather than assuming.
4. **Whether this is a ratio in disguise.** It must not be. 011 deleted a
   yield floor because volume cannot tell you a page's *type*; the objection
   does not reach here, because choosing between candidate roots by size is a
   structural question with a structural answer -- which element holds the
   document -- not a judgement about what kind of page it is. Worth stating in
   the code, since the two look alike from a distance and the next reader will
   have 011 in mind.
5. **What this does not fix.** moonofalabama returns 128,718 characters around
   a 9,569-character post because `#content` legitimately wraps the post *and*
   a hundred comments. No root rule reaches that: the comments are visible
   content, and separating them from the piece is the page-type judgement 011
   ruled out. That case is 025's, and it is why `article` stays.

### Tested

A page with many decoy `<article>` cards is a fixture, not a live fetch --
the failure is entirely in the selection, so it can be a small HTML document
served to the walker. 001's rule applies: this earns a test because it
happened.

### Re-checked against 025's pages

[Whether dom alone is enough](025-whether-dom-alone-is-enough.md) closed on a
verdict that a repaired root could in principle overturn, so the check rides
here rather than in a ticket of its own -- this is the change that would
invalidate it, and the only place it can be run.

After the fix, re-run the five pages 025 measured. The expected result is that
it splits them:

- **americanthinker recovers.** The decoy is the whole failure; `dom` should
  reach the 5,769-character piece rather than the 273-character promo card.
- **moonofalabama does not.** `#content` is the right container and still
  holds a hundred comments. If a root rule *did* fix it, 025's verdict was
  wrong and `article` may not need to stay -- so an unexpected win here is a
  finding, not a bonus.
- **chinadaily, chinanews and gmw are unchanged.** They fall through to `body`
  and there is no better candidate; a rule that moves them has changed
  something it was not asked to.

## Answer

**A selector that matches more than once has not found the document.** It has
found a collection, and `querySelector` hands back the first member of it. The
walker now skips any selector with a match count other than one, and
americanthinker's thirty `<article>` cards stop being a root:

    _ROOTS = ("main", "[role=main]", "article", "#content", "#main")

    for (const sel of roots) {
      const els = document.querySelectorAll(sel);
      if (els.length !== 1) continue;
      if ((els[0].textContent || '').trim().length > 40) { root = els[0]; break; }
    }
    root = root || document.body;

### Question 1: largest-wins was rejected, and it would have been a bug

The ticket proposed keeping the element with the most text. `body` is a
superset of every other candidate, so it wins that comparison on every page
ever loaded -- the rule deletes the heuristic it was meant to repair. Excluding
`body` and comparing the rest only moves the problem: no page measured has two
unique candidates that disagree, so the comparison would be speculation
wearing a measurement's clothes.

Counting is enough, and it is enough because it is the same evidence read
correctly. Thirty `<article>` elements are not thirty candidate roots; they
are one fact about the document, which is that it is a listing.

`body` is out of `_ROOTS` for the same reason. It matched once and held
everything, so as a candidate it could never lose; it is the fallback, and the
walker now names it as one. The behaviour is identical either way -- a `body`
under 40 characters fell through to `body` before too.

### Question 2: `article` needs no rule of its own

This was the ticket's own suggestion -- distrust `article` when the page holds
many -- and it turns out to be the general rule rather than a special case.
Two `<main>` elements are the same kind of evidence, and so are two `#content`
divs in invalid markup. Nothing in the walker mentions `article`.

### Question 3: the 40-character guard survives, with a smaller job

It was the whole test; it is now an emptiness check on a single candidate. A
JS app can leave a `<main>` shell it never filled, and the content then lives
elsewhere -- so an empty unique match must not win. It is not a quality bar
and does not compare anything, which is what keeps it clear of question 4.

### Question 4: not a ratio, and the code says so

Nothing is measured against anything else. `length !== 1` is a count of
matches, not a volume: the question "which element is the document" is
structural and gets a structural answer.
[011](011-listing-clears-the-yield-floor.md)'s objection is that volume cannot
tell you a page's *type*, and no judgement of type is made here. The comment
in `extract.py` states this, because the next reader will have 011 in mind and
the two look alike from a distance.

### Question 5: unchanged, as expected

moonofalabama still returns the post wrapped in a hundred comments. `#content`
is unique and is the right container; the rule reaches nothing there, which is
[025](025-whether-dom-alone-is-enough.md)'s finding and why `article` stays.

### Re-checked against 025's pages

Old walker and new walker run against the same live page in the same session,
so this is a before/after on one document rather than a comparison with the
table in 025 (whose articles have rolled off).

| Page | Candidates | `article` | `dom` before | `dom` after |
|---|---|---|---|---|
| americanthinker | 30 `<article>` | 5,769 | **277** | **43,981** |
| moonofalabama | unique `#content` | 56,477 | 62,491 | 62,491 |
| chinadaily | none | 1,639 | 7,780 | 7,780 |
| chinanews | none | 2,058 | 4,836 | 4,836 |
| gmw | none | 310 | 24,495 | 24,495 |

The split the ticket predicted, exactly:

- **americanthinker recovers.** The 5,769-character piece is present,
  contiguous, and starts 8,296 characters in, with its outbound links intact
  -- where before it was absent and the reply was the promo card for it. The
  page has no `main`, no `#content` and no `#main`; the body lives in a
  `div.main_information` that no selector reaches, so the recovery is a fall
  through to `body`. That costs 7.6x furniture, which is the shape 025 already
  accepted on the three Chinese pages and on moonofalabama's 13.5x. Content
  wrapped in obvious furniture is a cost; content replaced by an advert for
  itself is a lie.
- **moonofalabama does not.** Unchanged to the character, so 025's verdict
  stands and `article` stays.
- **chinadaily, chinanews and gmw are unchanged**, byte for byte.

### Tested: the suite now starts a browser

Three tests in `tests/test_walker.py`, against `set_content` fixtures -- the
failure is entirely in the selection, so nothing is fetched. The decoy test
fails against the old walker with the bug's exact signature (`'The real
piece.' not in '### [Teaser headline number 0]...'`), which is
[001](001-testing-the-shells.md)'s rule: a regression test that has never
failed is a claim, not a check. The other two are controls that pass on both
walkers -- a lone `<article>` is still a root, and an empty `<main>` is still
not one.

This is the first test in the suite to start a browser, and 001 said the suite
starts none. That ruling was about the nested cage/wayvnc/Chrome stack, whose
cost is an environment; a headless browser handed a string of HTML shares none
of it, and the walker is not reachable any other way. `test_extract.py`'s
docstring claimed the walker "is not reachable from here" -- that was a
constraint of not having tried.

`flake.nix` pins `pkgs.chromium` for `checks.default` and points
`AGENT_BROWSER_CHROME` at it, so the test runs rather than skips in the one
command that gates the repo. This does not reopen the flake's decision to take
Chrome from the host: that argument is about fingerprint drift on the browser
that faces sites, and a browser only ever handed a fixture string faces none.

### Surfaced while doing this

[The pid test loses its race in the nix sandbox](031-session-pid-test-is-flaky.md)
-- `nix flake check` went red on `test_session` and green on an immediate
re-run of the same derivation. Unrelated to anything here, and it makes the
gate unreliable.
