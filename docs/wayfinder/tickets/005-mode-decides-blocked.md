---
id: 005
title: The extract mode decides whether a page counts as blocked
labels: [wayfinder:task]
status: open
assignee:
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
