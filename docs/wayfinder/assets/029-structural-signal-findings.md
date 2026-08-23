# Is the comment thread a structural signature?

Asset for [One extractor instead of two](../tickets/029-one-extractor-instead-of-two.md),
decision 1. Measured 2026-08-24 against live pages through the tool's own
`script` door.

**What was tested.** Not an extractor -- the claim underneath it. 029 rests on
one sentence: moonofalabama's comment thread is "structurally a run of
near-identical siblings each carrying an author, a timestamp and a permalink --
which is a structural signature, not a volume ratio, and
[011](../tickets/011-listing-clears-the-yield-floor.md)'s objection does not
obviously reach it." If that is false the ticket is a port after all. So the
probe measures sibling *shape*, never text volume: for each container, group its
children by `tagName` plus the sequence of their own children's tag names, and
report how the text divides between groups.

## The comment thread is unmistakable

`#content` on a 233-comment post, 106 children, 61,649 characters:

| shape | count | text |
|---|---|---|
| `DIV[A,P,P]` | 81 | 40,133 |
| `DIV[…the post…]` | **1** | 5,572 |
| `DIV[A,BLOCKQUOTE,P,P]` | 9 | 4,557 |
| eight further `DIV[A,…]` variants | 9 | ~10,400 |
| furniture (respond form, nav, footer) | 6 | ~740 |

100 of the 106 children are `div.comment*` holding **90%** of the text, every one
of them starting with an anchor -- the permalink -- and 81 sharing an internal
shape exactly. The post is a single child with a shape that occurs once.

Classes had to be ignored to see it. WordPress alternates `even`/`odd` and
`thread-even`/`thread-odd`, which splits one logical run into four and was the
first probe's wrong answer (41, not 100). **A signature that reads classes will
undercount this run**, which is worth knowing before anyone builds on one.

## But "a repeated run" is also what a listing is

That is 011's objection arriving one level up, and it is the real test. Three
pages, same probe, asking additionally whether any *uniquely* shaped sibling
holds prose:

| page | run | run share | biggest unique sibling |
|---|---|---|---|
| Hacker News front page | 30 x `TR[TD,TD,TD]` | 0.536 | **0** |
| moonofalabama post | 81 x `DIV[A,P,P]` | 0.651 | 5,572 (0.09) |
| moonofalabama front page | *none* in the content container | -- | every entry a different shape |

**The discriminator that survives these three is structural.** A repeated run
*beside a uniquely-shaped sibling holding prose* is a document with its comments;
a repeated run with **no** such sibling is a page that *is* the listing. Hacker
News has no document child at all -- there is nothing there but the run. The
comment page has exactly one. Nothing in that rule measures a ratio, so 011's
objection does not reach it.

The moonofalabama front page is a third shape again: many entries, but each with
a *different* internal structure, because each is a full post body. It has no run
to strip.

## Where this is fragile

**The unique sibling is only 9% of its container.** So the rule cannot be "the
document is the big one" -- it is "a uniquely-shaped sibling with substantive
prose exists". That is a low bar, and the obvious false positive follows: **a
listing page with a lead paragraph.** Search results under an intro sentence, a
category page with a blurb, a forum index with a pinned notice -- each is a
repeated run beside one uniquely-shaped prose sibling, and the rule as stated
would strip the listing. That is exactly the failure `dom` exists to prevent.
**Not tested**, and it is the next thing to test.

**Three pages is three pages.** 025's five-page acceptance set has not been run
against this, and a signal that works on one comment thread is not a mechanism.

**The probe has a bug worth not inheriting:** ranking containers by run text
picks `HEAD`, because `innerText` on a `<style>` element returns its source. Any
real implementation walks rendered elements only.

## What this does and does not settle

It settles the claim 029 rests on: the comment thread *is* structurally
distinguishable, without measuring text volume, and the same probe tells a
listing apart from it on the cases tried. That was the thing most likely to be
false, and it is not.

It does not settle decision 1. One mode also has to find the root without a
selector list ([028](../tickets/028-the-root-heuristic-picks-a-decoy.md)), keep
withheld-content markers, see what is invisible, and emit tables. This measured
one requirement -- the one 025 called the single reason `article` survived.

## A gap found on the way

**025's acceptance set has no URLs.** The five pages are named by site
(chinadaily, chinanews, gmw, americanthinker, moonofalabama) and by character
count, and nowhere -- ticket or assets -- is the URL of any of them recorded. So
the acceptance set cannot be re-run as measured; it can only be approximated
with fresh pages from the same sites, which is a different measurement. Whoever
continues 029 should record URLs for the set they use, so the third person does
not have this problem too.
