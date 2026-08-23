---
id: 028
title: The root heuristic picks a decoy
labels: [wayfinder:task]
status: open
assignee:
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
