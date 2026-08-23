---
id: 019
title: The tool does not learn; the agent remembers
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: [018]
---

## Question

[The extract mode decides whether a page counts as
blocked](005-mode-decides-blocked.md) deleted the thing that *wrote* to
the signature registry and deliberately kept the half that curates it --
`pending_review`, `approve`, `forget`, the on-disk `learned` list. That
was the conservative call at the time. The stance now is that the whole
mechanism should go, and for a reason better than "nothing fills it".

**A tool that learns is a second memory, owned by the wrong party.** The
caller here is an agent with its own persistent memory, one that already
holds project-scoped facts across sessions and that a human can read and
correct. "This site puts its comments behind a login", "that domain sits
behind DataDome" is exactly that kind of fact. Putting it in
`signatures.json` instead files it somewhere the agent cannot see, cannot
explain, and cannot revise -- it can only be surprised by it. The eight
proposals 005 found on disk were invisible to every session that would
have been affected by them.

The failure mode is not hypothetical. A learned rule is a judgement made
once, from one page, that then acts silently and forever. Agent memory
has the opposite shape: written deliberately, attributed, re-read in
context, and cheap to delete when it turns out to be wrong.

Note the builtins are a different thing and stay. Cloudflare, Turnstile,
hCaptcha, Arkose, DataDome, PerimeterX, login walls -- that is a fixed
table of how the world's challenge vendors identify themselves, shipped
with the tool and true regardless of who is calling. It is knowledge
about *challenge vendors*, not about the caller's sites.

Blocked on [Asking for a human, rather than being guessed
at](018-asking-for-a-human.md), and this is the real dependency rather
than a formality: today a site-specific signature is the only way to make
a handoff fire on a site the builtins do not recognise. Remove learning
before a caller can ask for a human deliberately and that becomes
unreachable. Afterwards it is the agent's job -- read the page, recognise
the wall, remember it, ask for the human next time.

To decide:

1. How much comes out. `Registry.learned`, `pending_review`, `approve`,
   `forget`, `load`/`save`, the `signatures.json` file itself, and the
   `Signature` fields that only served proposals (`seen_at`, `evidence`).
   `active()` collapses to `BUILTIN`, and the registry stops touching
   disk at all.
2. What `signatures` the command becomes. Listing the builtins is still
   worth having -- it is how a caller learns what the tool can recognise
   without reading the source.
3. Whether anything should be said at the boundary. If the tool no longer
   remembers, the thing that does needs to be told: a line in the MCP
   tool description, or in the `blocked` hint, that recognising a wall
   this tool does not know is the caller's to record.
4. What to do with an existing `signatures.json` on disk. Ignoring it
   silently is one answer; refusing to start is not.

## Answer

Removed, and not replaced. `registry.py` is gone in full -- `load`, `save`,
`active`, `listing`, `approve`, `forget` -- along with the `Registry` model,
`config.signatures_file`, `RegistryError`, `REGISTRY_CORRUPT`,
`SIGNATURE_NOT_FOUND`, and the `pending_review` / `seen_at` / `evidence`
fields that only ever served proposals. `Signature.condition` went with them:
it rendered a row for a listing that no longer exists.

**No caller can observe this landing.** `active()` returned `BUILTIN +
[approved learned]`, and the learned list has been empty since 005 deleted
what wrote to it -- the `signatures.json` on this machine reads `{"learned":
[]}`, 19 bytes. So this is the removal of a mechanism that has been inert for
several tickets, not a change in what comes back `blocked`.

**The table stopped being a parameter.** `classify`, `probe` and
`selectors_of` each took a `signatures` tuple, threaded from `registry.active()`
by both call sites. With one possible argument, forever, that parameter
advertised a variation nobody wants: it is precisely the seam a future session
would fill by handing in a second table. They read `BUILTIN` directly now. The
cost is real and was taken deliberately -- a test wanting a different table
monkeypatches `ab.detect.BUILTIN` instead of passing one, which is the weaker
shape, and it buys the stronger statement that there is nothing to pass.

**The `signatures` command is gone, and `status` says the useful half.** With
nothing to curate, the command's whole remaining job was printing a constant --
and it left `--approve` and `--forget` shaped holes inviting a refill. What is
worth keeping is that a human can see what the tool is able to recognise
without reading the source, so `status` grew one line:

    recognises: cloudflare-interstitial, cloudflare-turnstile, recaptcha,
                hcaptcha, arkose-funcaptcha, datadome, px-human, login-wall

It arrives where someone already looks when a fetch surprised them, and the
README now points at it rather than keeping its own prose copy of the list.

**An existing `signatures.json` gets no mechanism.** Ignoring it silently was
weighed against a `status` note and against deleting the file. Every option
deleted the same code; they differed only over the orphan left on disk. A
warning means keeping a parser for a format being deleted, and it fires as
noise on the empty file that is the only one known to exist. The population of
affected machines is one, its file is empty, and ticket 033 moves the state
directory anyway. If this is ever handed to someone whose file is not empty,
that is a line in a release note, not a mechanism in the tool.

**Point 3 was taken, in `fetch`.** The MCP `fetch` docstring now says the tool
recognises a fixed table and nothing else, that it learns nothing between
calls, and that a wall it cannot name is the caller's to recognise and to
remember. It is a fourth hand-written statement of something the server
instructions, `show_browser`'s docstring and the README already say -- taken
knowingly, because it arrives at the moment of use rather than at session
start, which is [Six skills restate the server
instructions](032-skills-restate-the-instructions.md)'s point 3 and its
cheapest experiment. That 032 remains the ticket that decides where this
knowledge should live; this is one instance, not the answer.

`mypy --strict` clean over 20 files, 33 tests pass, and a live `fetch` of
example.com still classifies as content.
