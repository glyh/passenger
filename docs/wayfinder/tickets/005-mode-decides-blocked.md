---
id: 005
title: The extract mode decides whether a page counts as blocked
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

The same page, fetched twice in a row, came back as content and as
blocked depending only on `mode`.

`ratchakitcha.soc.go.th/search-result/`, a JS-rendered listing:

    mode=dom      → fetched, 2,109 words
    mode=article  → blocked, name "unknown-blocker"

Nothing about the page differed. `probe` takes `word_count` from the
extraction it is handed, and that extraction is the mode-specific one, so
`classify` is deciding liveness from a number that a *presentation*
choice produced. trafilatura finds nothing in a JS app -- which is the
documented reason `dom` exists -- and a near-zero word count is exactly
what `NovelBlocker` is looking for. `auto` is immune, because `choose`
measures both; only an explicit `article` can produce the false verdict.

(Premise corrected after this was written: `page.content()` is the rendered
DOM, so trafilatura is not blind to a JS app -- it discards the listing as
boilerplate. See [Whether defuddle belongs alongside trafilatura as an extract
mode](009-defuddle-as-a-mode.md).)

The second half is worse than the first. Having decided the page was
novel, `propose_signature` found no third-party iframe and fell through
to the title branch, offering:

    ^ราชกิจจานุเบกษา

That is the site's own name, carried by every page on it. Approving it
would mark the entire domain permanently blocked -- and the proposal
arrives at exactly the moment the agent is least able to judge it, having
just been told the page is unreadable. The title branch is sound for
`^Just a moment`, where the title belongs to the challenge; it is unsound
whenever the title belongs to the *site*, which is the normal case for a
single-page app -- the same class of page that reaches this code by the
route above.

To decide:

1. Whether blocked-ness should be measured independently of the requested
   mode -- the honest reading is the best available extraction, not the
   one the caller asked to be shown.
2. Whether a novel-blocker verdict should require corroboration beyond a
   low word count. There is already richer evidence in hand at that point
   (iframe srcs, visible prompts, the screenshot); a thin page with no
   challenge-shaped thing on it may simply be a thin page.
3. Whether the title branch of `propose_signature` should survive at all,
   and if so what makes a title challenge-specific rather than
   site-specific. A title that is stable across a site's pages is the
   thing to reject, but a single observation cannot see that.
4. Whether a rejected proposal should be remembered. Nothing currently
   stops the same bad rule being offered on every subsequent fetch.

Cheap regression seams, if [What the test suite covers, and how the
shells get tested](001-testing-the-shells.md) lands first: both halves
are pure. `classify` against a fixture probe, and `propose_signature`
against a fixture `Evidence`, need no browser.

## Answer

The tier is gone, not fixed.

The bug was real but it was a symptom. Feeding `probe.word_count` from
the mode-specific extraction is what let a *presentation* choice decide
liveness -- but the deeper fault is that the verdict had no business
existing. The test that settles it: **does the tool know anything the
caller does not?** For a signature match, yes, and things the caller
cannot see -- a third-party challenge iframe, a title, a URL pattern,
none of which cross the boundary. For a `NovelBlocker`, no. Its entire
evidence was `word_count`, which is already on `Fetched`. It was ruling
on a number it hands over anyway.

So `classify` is one tier now: a signature matched, or it did not.
`min_words` is gone from the request models, both doors, the CLI, the
MCP schema and the environment. A short page is a short page; the caller
gets the content and the count and decides.

The second half of the ticket -- `^ราชกิจจานุเบกษา`, a proposal that
would have blocked a whole domain by its own name -- dissolves with it.
The learning path had exactly one trigger, so `propose_signature`,
`record_novel`, `capture_evidence`, the `Evidence` model and
`registry.remember` are all gone, along with `Blocked.evidence` and
`Blocked.proposed_condition`. The curation half of the registry stays:
`active()` still excludes anything `pending_review`, and `signatures
--approve/--forget` still work on what is already on file. What was
removed is the guessing, not the review.

Verified: `fetch https://example.com` returns its thirty-odd words and
exits 0; `fetch https://github.com/login` still comes back `blocked`
naming `login-wall` and exits 2.

This also closes [A fetch of an ordinary page put the browser on screen
and waited](010-fetch-seizes-the-screen.md), which was the same defect
seen from the handoff end.

### What it costs

A genuinely new challenge -- a vendor with no signature yet -- now
returns as thin content, and no human is summoned. The caller can *see*
that, and cannot say so: `wait_seconds` and `--handoff` only do anything
once the tool has already decided the page is blocked. Recorded as
[Asking for a human, rather than being
guessed at](018-asking-for-a-human.md); handoff as something requested
is the better shape anyway, and it is the same evidence-not-verdict move
that 014 and 015 both landed on.
