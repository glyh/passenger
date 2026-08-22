---
id: 011
title: A listing clears the yield floor on a footer
labels: [wayfinder:research]
status: open
assignee:
blocked_by: []
---

## Question

`auto` runs `article`, and falls back to `dom` only when the article
extractor recovered under 35% of the page's visible words. On the
xiaohongshu search page -- the page that
[A listing read through dom mode has no link targets](007-links-lost-in-dom-mode.md)
was written about -- the numbers are 251 words against 646, a ratio of
0.39. Just clear of the floor. So `auto` returns 2,184 characters of ICP
footer and legal boilerplate, and the caller has to know to ask for
`mode=dom` by name to see the twenty result cards and their tokens.

Ticket 008 fixed the counting; the ratio is now measured with a ruler that
works on Chinese, and the extractions are the real ones. The floor is
simply not tripped. Nudging 0.35 upward is the obvious move and the
suspicious one: the number was picked to catch "the article extractor
gutted the page", and a footer is not a gutted article, it is a *different
page*. Two extractions can be similar in volume and disjoint in content,
and a ratio cannot see that.

To decide:

1. Whether volume is the right signal at all, or whether the comparison
   should be about overlap -- how much of what `dom` saw does `article`
   still contain? A footer shares almost nothing with a listing; a real
   article shares nearly everything with the DOM text around it.
2. Whether link density is a legitimate second signal now that both modes
   emit links. Forty labelled links to forty distinct paths is what a
   listing *is*, and no amount of prose looks like that. Note the trap
   recorded in 007: counting link markup as words gets the right answer
   here for the wrong reason, and `unlinked()` exists to stop it.
3. Whether `auto` should be allowed to return *both*, or say which it
   rejected and why. Today the decision is invisible to the caller; a
   fetch that quietly returned the footer looks identical to a fetch of a
   page that really is a footer.
4. Whether this interacts with
   [The extract mode decides whether a page counts as blocked](005-mode-decides-blocked.md).
   Both are the same shape of problem -- a threshold on a word count
   standing in for a judgement about what the page is.
