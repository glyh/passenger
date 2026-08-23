---
id: 011
title: A listing clears the yield floor on a footer
labels: [wayfinder:research]
status: closed
assignee: lyh (via Claude)
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

## Update: downstream already gave up on `auto`

Checked the consumers in `~/Documents/Notes/skills`. Two of them use
agent-browser for reading pages, and both independently concluded that
`auto` cannot be trusted -- before this ticket was written, and without
reference to it.

`xiaohongshu/SKILL.md` heads its rules with **"模式按页面类型钉死，不要用
auto"** -- pin the mode to the page type, do not use auto -- and carries a
table of which mode each page needs:

    /search_result      dom       article/auto return only the ICP footer
                                  and the filter words, not one card
    /explore/<id>       article   dom glues the whole recommendation feed
                                  in front of the note body
    /user/profile/<id>  dom       article loses the note list
    /explore            dom       article leaves only navigation words

It then diagnoses this ticket exactly, unprompted: *"它靠两种抽取的词数比
来决定，而搜索页的比值 0.39 刚好越过 0.35 的回退地板"* -- it decides on the
word-count ratio of the two extractions, and the search page's ratio of
0.39 just clears the 0.35 fallback floor. Same numbers, arrived at from
the outside.

`web-search/SKILL.md` is blunter -- **"`mode: "dom"`，永远"**, mode dom,
forever -- and reports a worse failure than the footer. On Bing, `article`
returns *plausible unrelated content*: a query about an airport's
construction progress came back with Instagram troubleshooting and GPU
tier lists, described as *"看着像正常结果，实际全是噪音"* -- looks like
normal results, actually all noise. Of Google it says `auto` sometimes
works by luck but loses results, *"别赌"* -- don't gamble.

### What this does to the question

It reframes it. The ticket asks whether volume is the right signal, or
whether overlap or link density would be better. The evidence says the
signal may not be the problem: **the right mode is a function of page
type, and page type is something the caller knows and the tool cannot.**
A site-specific skill knows it is on a search results page. `choose` has
to infer it from two blobs of text, and the failure when it infers wrong
is not a near miss -- it is a confident footer, or noise that reads like
an answer.

That makes a fourth option worth weighing against the first three:

4. Whether `auto` should stop being the default, or stop existing. Every
   real consumer pins the mode already, so `auto` is serving nobody except
   a caller with no site knowledge -- and for that caller it produces
   exactly the silent wrong answer this codebase has spent 005, 010 and
   016 removing. Against: it is the current default, so this is an output
   contract change, and a caller who genuinely does not know the page type
   has to be given something better than a coin flip.

Note also what the same skill says about `fetch` against `script`:
*"默认用 fetch——大多数问题第一屏就答完了"* -- default to fetch, most
questions are answered by the first screen. That is [How thin can this
layer get](020-how-thin-can-this-layer-get.md)'s decision to keep `fetch`,
confirmed from the outside.

## Answer

The floor is not the bug. `auto` is.

The ticket's first question -- whether volume is the right signal at all
-- turns out to be the whole thing, and the answer is that no signal
computed from the two extractions can work, because the information
needed is not in them. Which extractor is right depends on what *kind of
page* this is: a listing wants `dom`, an article wants `article`, a
profile wants `dom`. `choose` is handed two blobs of text and asked to
infer that, and every candidate signal in this ticket -- volume, overlap,
link density -- is a proxy for page type rather than a measure of it.

Proxies fail quietly here, and that is what disqualifies them. The
footer case is the polite failure: 0.39 against a 0.35 floor, and the
caller gets boilerplate. The impolite one is downstream's Bing
observation -- `article` returning content that is coherent, on-topic in
shape, and entirely unrelated to the query. A wrong page type does not
degrade the answer, it replaces it.

Nudging the floor would move which pages fail. Overlap and link density
would move it again, better on the cases measured and unknown on the
rest. None of them make the number mean the thing it needs to mean.

Meanwhile the caller *does* know the page type -- every consumer of this
tool already pins the mode by URL shape, and has done since before this
ticket existed. So the honest move is not a better heuristic. It is to
stop guessing and let the caller say, which is the same conclusion 005
reached about `min_words` and 016 reached about deferred content: this
layer keeps trying to decide things the caller is better placed to
decide.

Superseded by [Remove auto mode](021-remove-auto-mode.md), which is the
removal and its consequences -- including what is left of the word
counting once nothing decides anything with it.
