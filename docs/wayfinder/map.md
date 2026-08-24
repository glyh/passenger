---
labels: [wayfinder:map]
---

# Making the nested browser stack trustworthy

## Notes

**Domain.** `passenger` fetches pages through a real, logged-in
Chrome that sites cannot distinguish from an ordinary browser. Chrome
runs inside its own `cage` compositor; `wayvnc` serves that compositor,
and a viewer is spawned on demand when a human has to take over -- solve
a captcha, log in. The value of the whole tool rests on two things: the
session staying warm and real, and the handoff to a human actually
working when it is needed.

**This effort.** The stack was recently found to be silently broken in
the handoff path: a stale `wayvnc` served a dead compositor while every
status read healthy, so `show` produced a black screen. That specific
correlation bug is fixed (commit 5275197 -- per-session port and control
socket, a session record written from inside cage, pid-scoped teardown).
What remains is everything that made it possible: no tests, and a
presentation layer nobody had looked at closely.

**Skills to consult.** `python-as-ocaml` and `python-design-patterns` --
the codebase is deliberately functional-core / imperative-shell, with
pydantic models parsed at every boundary and no raw dicts downstream.
Match that style rather than introducing a new one. `tdd` is relevant to
[What the test suite covers, and how the shells get tested](tickets/001-testing-the-shells.md).

**Standing preferences.** Docstrings explain *why*, and say what the
prior wrong behaviour was when a comment guards against its return.
Single developer, no remote: commit to `trunk`, do not branch.

**The tool does not learn.** Anything durable this tool discovers about a
*site* belongs in the calling agent's memory, not in state of its own. A
tool that remembers is a second memory owned by the wrong party: invisible
to the agent it would help, unexplainable, and revisable only by surprise.
The builtin challenge signatures are not an exception to this — they are a
fixed table about how vendors identify themselves, true regardless of who
is calling. See [The tool does not learn; the agent
remembers](tickets/019-the-tool-does-not-learn.md).

**The tool measures; the skill judges.** The tool reports what it *measured* --
which since ticket 048 is one thing, a vendor's own markup -- and never rules on
what a page *means*. 048 went further than the rule required: a fraction of the
viewport and a character count were both honest measurements and were deleted
anyway, because nobody had asked for them. Recognition patterns and heuristics live
in the `using-passenger` skill, where a caller reads them, rather than in a table
this side matches. Four mechanisms have now been deleted for crossing that line
(a yield floor, a `min_words` tier, a learned signature registry, a wall hint);
`BUILTIN` stays, because a vendor either serves that markup or does not. See [A
Fetched that says this reads like a
wall](tickets/038-a-fetched-that-says-this-reads-like-a-wall.md).

**A lane is bookkeeping, not memory.** Ticket 019 forbids the tool holding
durable knowledge about a *site* behind the agent's back. Lane membership is a
different animal and the distinction is now load-bearing: it is about this
session's own tabs, the caller can read all of it back with `list_tabs`, and it
does not survive a Chrome restart. State that fails any of those three is 019's
problem again. See [A lane owns its
tabs](tickets/040-a-lane-owns-its-tabs.md).

**Lanes partition ownership, not availability.** One profile is one Chrome and
one attach, and attaching initialises every open tab — so a tab wedged in any
lane still costs every lane, and freeing it can stop another lane's navigation
(ticket 012's closing trade). Not fixable short of separate profiles, which
would throw away the warm session, so it is measured and named rather than
prevented.

**`walker.js` is `markdown.js`.** Renamed 2026-08-24, in
`skills/using-passenger/`. Everything closed below says `walker.js` and means
this file; history was left as it was written. The traversal is still a walk,
and the code still calls it one -- what changed is the name a caller reads,
which now says what the recipe produces rather than how.

**The layer stays thin.** The agent does the work; this side hands over the
capability and gets out of the way. Ticket 004 settled that for verbs — one
door with `page` bound, rather than a tool per Playwright call — and the same
question is owed to every tool that predates it. See [How thin can this layer
get](tickets/020-how-thin-can-this-layer-get.md).

## Decisions so far

<!-- one line per closed ticket -->

- [Sizing the cage output to the viewer's real window and scale](tickets/002-vnc-output-sizing.md)
  — the viewer owns the size and asks for it over RFB, continuously; this
  side keeps only the scale. The local presenter is now the viewer page in
  a chromeless window of the host's own browser, not a native VNC client.
- [Whether the viewer can drive the resize itself](tickets/003-client-driven-resize.md)
  — it can. `SetDesktopSize failed: 4` is printed and the resize happens
  anyway; the refusal that justified measuring windows from this side was
  never real.
- [The human takes over a browser with no address bar](tickets/006-no-address-bar-in-handoff.md)
  — cage's fullscreen was hiding Chrome's own toolbar. The window is taken out
  of fullscreen over CDP, permanently, so the handoff hands over an ordinary
  browser rather than a bare page.
- [Word counts assume spaces, so CJK pages read as empty](tickets/008-word-counts-assume-spaces.md)
  — one `count_words`, ICU's dictionary segmentation, shared by `classify`
  and `choose`. A 1,890-character Chinese note counted 1 word and now counts
  1,050; `min_words` keeps its meaning in every script. The Python side moved
  to nix in the same change, since PyICU is the project's one native
  dependency and was resolving against the host's libicu.

- [A listing read through dom mode has no link targets](tickets/007-links-lost-in-dom-mode.md)
  — `dom` emits `[label](url)` inline, always, resolved against the document
  and never normalised, because a signed query string *is* the URL. The walk
  that does it also exposed the real bug: `innerText` on a detached clone is
  `textContent`, so `dom` never had block boundaries. Link markup is stripped
  before any word count, so density cannot masquerade as content.

- [Whether defuddle belongs alongside trafilatura as an extract mode](tickets/009-defuddle-as-a-mode.md)
  — no. Measured on six pages: it wins only on fenced code blocks in
  documentation and loses links everywhere else, which is what 007 needs.
  The measurement also corrected the premise -- `page.content()` is the
  rendered DOM, so trafilatura already sees a JS app and discards it as
  boilerplate rather than failing to see it.

- [Reaching content that sits behind an interaction](tickets/004-driving-the-page.md)
  — all the way up the Playwright surface, but through one door: a tool that runs
  caller-supplied Python with `page` bound, tabs addressed by CDP `targetId`, and
  the existing probe/classify run on whatever page the script ends on. No verb is
  rewrapped and no `read_current` is needed. Measured alongside it: CDP input is
  `isTrusted`, but `click` teleports the cursor and `fill` types nothing — so
  reading and driving are different kinds of act, not degrees of one.

- [One wedged tab bricks every later call](tickets/012-one-wedged-tab-bricks-every-call.md)
  — the attach is bounded, and a failed one now frees what is holding it rather
  than reporting. Two holders, and the second was ours: a navigation that never
  lands silences the renderer, and an abandoned attach keeps every request paused
  for interception. Recovery talks to the browser process directly, since
  patchright is the thing that is stuck, and stops the navigation rather than
  closing the tab.

- [The passthrough tool that runs a script against a page](tickets/013-the-passthrough-tool.md)
  — built at both doors: caller-supplied Python with `page` and `read(page)` in
  scope, tabs by CDP target id, and `service.inspect` shared with `fetch` so the
  ending page is classified the same way. A locator that tries to cross is told
  what to return instead; a script that raises comes back as an outcome with its
  own line number, not an exception.

- [Content that lives in pictures reads as an empty page](tickets/014-content-that-lives-in-pictures.md)
  — no extraction change. `script` reaches images through the warm session
  (`page.request.get`: 200, or `locator.screenshot()` with no URL at all), so the
  caller asks for exactly the pictures it wants and hands itself a file path to
  read. The questions about inline markdown, `alt`, and capping URL bloat were all
  questions about everyone's markdown, and stop being asked.

- [Only the first screen exists](tickets/015-only-the-first-screen-exists.md)
  — the page says how much it withheld (`共 153 条评论`, five `展开 N 条回复`)
  and the extraction already contains every one of those strings. Scrolling
  once to see whether the page grew was rejected: it points at the wrong
  content on a note, and it makes every read a driving act.
- [The result says what it did not reach](tickets/016-the-result-says-what-it-missed.md)
  — and then nothing was built, because 015's own finding kills it. If the
  markers are in the markdown the caller holds, reading them is the caller's
  job; a per-language regex table is a worse recognizer than the agent it would
  serve. The problem was attention, not information, and the remedy is a
  sentence in the agent's memory rather than machinery here. Revisit only if
  output is ever capped, since markers can then fall outside what the caller
  receives.

- [The extract mode decides whether a page counts as blocked](tickets/005-mode-decides-blocked.md)
  — the tier is gone, not fixed. A signature match is a positive claim made from
  things the caller cannot see; a word count under `min_words` was the tool
  ruling on a number it hands over anyway. `classify` is one dumb tier now, and
  the guessing that hung off the other one — evidence capture, proposed
  signatures, `registry.remember` — went with it. The registry's curation half
  stayed.

- [The tool does not learn; the agent remembers](tickets/019-the-tool-does-not-learn.md)
  — and the curation half 005 kept is gone too: `registry.py` in full, the
  on-disk `signatures.json`, `--approve`/`--forget`, and the `Signature` fields
  that only served proposals. No caller could observe it landing — the learned
  list had been empty since 005 — which is the point: a mechanism nothing fed
  was still a second memory owned by the wrong party. The table stopped being a
  parameter as well, since one possible argument is a seam, not a choice.
  `agent-browser signatures` gave way to a `recognises:` line in `status`, and
  the MCP `fetch` docstring now says outright that a wall it cannot name is the
  caller's to remember.
- [A fetch of an ordinary page put the browser on screen and waited](tickets/010-fetch-seizes-the-screen.md)
  — closed by 005, from the other end. The handoff is reached only on a
  signature match, so the strongest action the tool has is triggered only by its
  strongest evidence. `fetch https://example.com` returns thirty-odd words and
  exits 0.

- [How thin can this layer get](tickets/020-how-thin-can-this-layer-get.md)
  — seven tools, and that is the floor. `list_blockers` returned a table that
  does not change between calls, and the caller learns the name of what is in
  the way from the `blocked` record anyway; it is gone. Everything else is
  capability: `fetch` stays as a deliberate exception to the no-second-ways
  rule because the common case should cost no code, `list_tabs` must work when
  a renderer does not, and presenting a compositor is not reachable from
  `page` at all.

- [A listing clears the yield floor on a footer](tickets/011-listing-clears-the-yield-floor.md)
  — the floor is not the bug, `auto` is. Which extractor is right depends on
  the page's *type*, which is not in the two blobs of text `choose` is handed,
  so volume, overlap and link density are all proxies for a thing they cannot
  measure. Every consumer already pins the mode by URL shape. Superseded by
  [Remove auto mode](tickets/021-remove-auto-mode.md).

- [What the test suite covers, and how the shells get tested](tickets/001-testing-the-shells.md)
  — the suite is a list of scars: a test earns its place by naming a failure
  that happened, and no coverage bar pulls it toward the modules that never
  broke. No seam for `_alive` — a real zombie is `Popen(["true"])` unreaped,
  so the test runs against the actual `/proc` read. Real processes, but only
  `true` and `sleep`; nothing starts the real stack. `nix flake check` runs it,
  and `conftest.py` redirects state before import, without which a test would
  SIGTERM the developer's own session.

- [Teardown gives up quietly](tickets/024-teardown-gives-up-quietly.md)
  — SIGTERM is escalated to SIGKILL, and the record is kept in the one case
  where even that fails. The old wait ended in a shrug: the budget ran out and
  the record was unlinked anyway, which is the port drift 5275197 fixed with
  the pid that causes it made unowned. Leaving the record for `reap_stale`
  alone does not converge, since that path only sends another SIGTERM. Both
  `teardown` and `reap_stale` now return what would not go, and the CLI prints
  it.

- [Asking for a human, rather than being guessed at](tickets/018-asking-for-a-human.md)
  — `show_browser` grew `tab`, `wait_seconds` and `notify_human`; still seven
  tools. The wait ends when the human closes the viewer, never on a reading of
  the page: with no signature to re-check, every "is it solved" signal is 005's
  deleted tier in new clothes, so the agent polls and judges. A presenter that
  cannot see its own window refuses the wait rather than reporting it over
  instantly. `Blocked` now names its tab, and a blocked fetch stops blanking it.

- [Whether dom alone is enough](tickets/025-whether-dom-alone-is-enough.md)
  — `article` stays, on one page out of five: moonofalabama wraps the post and
  a hundred visible comments in `#content`, and separating them needs the
  page-type judgement 011 ruled out. Where the ticket predicted `dom` would
  fail it read fine; both real failures were roots that matched the wrong
  element, which became [The root heuristic picks a
  decoy](tickets/028-the-root-heuristic-picks-a-decoy.md). `dom` also gained
  headings, list markers and fenced code — 34 fences to trafilatura's 8 on one
  asyncio page, where it had none.

- [Whether the payload is AsciiDoc rather than
  Markdown](tickets/027-asciidoc-rather-than-markdown.md)
  — no; markdown arrived as a default and is now kept on purpose. Three of its
  four considerations were answered by 025 and by the walker fix, all the same
  way, and the fourth was never measurable from here.

- [The root heuristic picks a decoy](tickets/028-the-root-heuristic-picks-a-decoy.md)
  — a selector matching more than once has found a collection, not the
  document, so the walker skips it. americanthinker's thirty `<article>`
  teasers stop being a root and its piece comes back: 277 characters to
  43,981, with the other four of 025's pages unchanged to the byte.
  Largest-candidate-wins was rejected — `body` is a superset of everything and
  would win on every page. First test in the suite to start a browser, with
  one pinned in `flake.nix` so it runs rather than skips.

- [Remove auto mode](tickets/021-remove-auto-mode.md)
  — `mode` is required at both doors rather than defaulted. `auto` compared
  two extractions by word count to answer a question about the page's *type*,
  which 011 showed is not in the text; the honest replacement is to ask the
  caller, who knows what it pointed at. The descriptions carry what `choose`
  was trying to compute, failure named: `article` returns the footer of a
  listing. `PageProbe.word_count` went too, so a presentation choice can no
  longer reach into a verdict -- 005's defect, now unrepresentable. `--dom`,
  and the never-read `AGENT_BROWSER_EXTRACT`, went with it. Unblocks [Drop
  ICU](tickets/022-drop-icu.md), which inherits the one open question: what a
  `word_count` nothing decides with should count.

- [Drop ICU](tickets/022-drop-icu.md)
  — the number is `char_count`, `len(text)`, and PyICU is gone with the
  question it answered. 008 was right for its consumers; both had since been
  deleted, leaving a dictionary segmenter -- the project's one native
  dependency -- carried for a display field. Characters are script-independent
  and track tokens better than words do, which is the caller's real question:
  the zh.wikipedia fixture reads 9,713 characters against 331 `split()` words.
  `len(text.split())` under the old name was the one forbidden replacement and
  the reason now lives on the property. Link targets are counted, since they
  are in the markdown the caller receives; `ab/text.py` and its tests are gone
  entirely. The flake stays -- it pins everything, not just the native build --
  and `uv.lock` went, a second dependency record nothing had read since
  7f50c99.

- [The pid test loses its race in the nix sandbox](tickets/031-session-pid-test-is-flaky.md)
  — the children announce themselves now, and the four `range(200)` polls are
  gone. Two seconds was a guess at a fork, an exec and an interpreter start;
  `pids_running` walks all of `/proc` per turn, so the poll grew slower under
  exactly the load that made it needed. The bound was not raised, because a
  gate that goes green on a re-run trains its one reader to re-run it. The
  `zombie` fixture keeps a poll — being dead is not a thing a child can say —
  but waits on its pipe reaching EOF first, so what is left is the tail of one
  kernel call.

- [The walker reads a snapshot, not the
  page](tickets/030-the-walker-reads-a-snapshot.md)
  — no. The walker stays JavaScript in the page, because that string is the
  one part of `extract.py` the C# port inherits unchanged — a Python walker
  would be written twice. Its other argument was already false: 028 had built
  the browser harness and pinned a chromium in the flake, so the testability
  the rewrite was buying was sitting unused, and a rewrite is an expensive way
  to write tests. Preserving `querySelector` over a snapshot was explored
  three ways and one was chosen before scope killed it —
  `el.querySelector('img[alt]')` runs once per anchor, so resolving selectors
  in the shell is four hundred roundtrips on a listing. What the ticket was
  right about is that the walker is untested, which is [A broken walker passes
  its own tests](tickets/034-broken-walker-passes-its-tests.md).

- [A broken walker passes its own
  tests](tickets/034-broken-walker-passes-its-tests.md)
  — it did: with the walker's JavaScript replaced by a syntax error, two of
  its three tests still passed, because `dom_text` fell back to
  `inner_text("body")` and the assertions could not tell. The fixture poisons
  `inner_text` now, so the fallback is unreachable in a test and the same
  experiment fails all thirteen; the fallback itself stays, because 012's
  wedged renderer really does stop answering. The walker moved to
  `passenger/walker.js` — 224 lines of `extract.py` down to 115, closures given
  names, no seam and no JavaScript runner — verified byte-identical against
  ten fixtures. Read once at import, which also made `pythonImportsCheck`
  catch the file missing from the wheel, as it promptly did.

- [checkVisibility() catches only
  display:none](tickets/035-checkvisibility-only-catches-display-none.md)
  — it did, and only one of the three missing options was worth taking. With
  no arguments the call reports on `display:none` alone, so
  `visibility:hidden`, `opacity:0` and `content-visibility` had all been
  leaking into every `dom` read. `visibilityProperty` is now on: it removed two
  lines of hidden furniture across nine pages and cost nothing.
  `opacityProperty` is refused on measurement, not caution — scroll-triggered
  reveal holds below-the-fold content at `opacity: 0` and this tool never
  scrolls, so apple.com fell from 13,081 characters to 3,761 of real body text,
  against a gain of three lines of dialog chrome. Furniture surviving is a
  cost; content vanishing is a lie. `contentVisibilityAuto` changed nothing
  anywhere and stays untaken.

- [A payload that is not text](tickets/017-a-payload-that-is-not-text.md)
  — the tool says so, in three fields, because this is the one thing it holds
  that the caller structurally cannot see. Geometry rather than a count: the
  largest visible picture as a share of the viewport splits thirteen pages
  cleanly (picture-borne 0.21–1.92, text 0–0.10), where a count and a summed
  area both call a 30-thumbnail listing more picture-borne than a three-photo
  note. `iframe` counts, because `walker.js` already treats it as opaque —
  without it apod.nasa.gov, the Astronomy Picture of the Day, measured 0.00.
  The ticket's own instinct was refused on measurement: "renders on top" is
  above-the-fold, not rendered, and a tool that never scrolls would lose
  moonofalabama's photograph entirely. No bucket word and no floor — 005 and
  021 removed ruling-on-your-own-number everywhere else.

- [Six skills restate the server
  instructions](tickets/032-skills-restate-the-instructions.md)
  — one `using-passenger` skill shipped from this repo holds the operating
  knowledge, and the docstrings are cut to the call contract rather than
  mirrored. The defensive reason for the copying turned out not to exist: two
  probes found no context where a docstring arrives but the server
  instructions do not — they are one channel, gated by the tool load, which
  also makes the ticket's "instructions arrive before there is a task"
  obsolete in this harness. What the probes did find is that before that load
  an agent has *neither*, which is planning time, and a skill is the only
  channel that reaches there. Field descriptions stay in full, since 021 chose
  `mode`'s as the replacement for deleted code. Point 4 is left live as [A
  Fetched that says this reads like a
  wall](tickets/038-a-fetched-that-says-this-reads-like-a-wall.md).

- [A Fetched that says this reads like a
  wall](tickets/038-a-fetched-that-says-this-reads-like-a-wall.md)
  — no, and nothing was built. Matching "verify you are human" is a
  per-language phrase table, the shape 005, 011 and 019 each deleted after it
  was wrong invisibly; the one new argument, that a wall reads as ordinary
  prose, is about attention, which 016 already answered. The product is the
  rule rather than the refusal: the tool reports what it measured, the skill
  holds what to look for. It stops at `BUILTIN` — a vendor's own markup is a
  fixed fact, and taking the rule further would delete the `blocked` outcome
  and the handoff with it. The wall phrases move into the skill as examples.

- [One skill for this server, and docstrings cut to the
  contract](tickets/036-one-skill-for-this-server.md)
  — `skills/using-passenger/SKILL.md` ships from this repo and is
  symlinked into the agent's skill directory; `fetch` lost four paragraphs,
  `show_browser` three, and the `instructions` block went from 1,400
  characters to a pointer. Field descriptions and the CLI are untouched. One
  sentence of prose stayed — `show_browser` is how you ask for a human
  deliberately — because when a tool applies is contract, not operating
  knowledge. The README was carrying the same paragraph and was trimmed the
  way 019 trimmed it before, which made it the third copy found, not the
  seventh.

- [The vault stops restating this
  side](tickets/037-vault-skills-cite-the-skill.md)
  — done in `~/Documents/Notes`. The six scraping skills lost every copy of the
  `blocked` / `show_browser` / `close_tabs` paragraph and now name
  `using-passenger`, keeping only what is theirs: Xiaohongshu's wall
  arriving as 「登录后查看搜索结果」, 58.com's self-made captcha showing up as a
  `title` that is not the target city, aqicn's global page under a different
  `<title>`. The vault's `CLAUDE.md` stays as bootstrap, because it is the only
  thing that fires before any skill or schema loads — but it lost the one line
  of tool behaviour it carried, `blocked` → a human must solve it, which was
  duplicated *and* wrong in the direction that matters. It gains the rule:
  vault skills carry site knowledge and cite tool knowledge by name. Cited in
  backticks rather than by wikilink, since a skill outside the vault has no
  path there and an unresolvable link is the dangling pointer this ticket
  deleted.

- [Rename agent-browser to passenger](tickets/033-rename-to-passenger.md)
  — done, in two commits: everything user-facing, then `ab/` → `passenger/`
  and `AgentBrowserError` → `PassengerError`. `AGENT_BROWSER_*` became
  `PASSENGER_*` with no alias, and the state dir went to
  `~/.local/share/passenger` with no migration code — the old profile is kept
  by a hand-made symlink, so nothing in the tree names the old path. The MCP
  registration has to be re-run: it pointed at `ab.mcp_server`, so an
  unchanged one does not start at all.
- [A lane owns its tabs](tickets/040-a-lane-owns-its-tabs.md) — a caller opens
  a lane and every tab it opens lives there; nobody else can see, list or close
  them. A sqlite registry under `state_dir`, because stdio means two
  `passenger-mcp` processes write it at once; a 30-minute TTL whose expiry
  closes the tabs; reserved `cli` and `orphan` lanes; a refcounted screen, so
  one lane's `hide_browser` cannot take the window from another's human. Tab
  bookkeeping left patchright entirely and goes through the CDP HTTP endpoint,
  which is what made a sweep cheap enough to run on every call. Eleven MCP
  tools where there were seven, and the closing verbs are separate rather than
  one with an optional selection: a destructive call must not express
  "everything" as an omitted argument.

- [The dom extractor returns nothing where inner_text returns a page](tickets/039-extractor-returns-nothing-on-12306.md)
  — closed undone. `dom` reads 0 characters and `article` a 22-row skeleton with
  every train number empty, on a 12306 page whose DOM holds 2647; nothing was
  probed and nothing was built, because the `railway-12306` vault skill already
  routes every caller down `inner_text` and nobody is blocked. What it settles by
  accident: that escape hatch has a production caller, so narrowing `script`'s
  scope would break it.

- [One extractor instead of two](tickets/029-one-extractor-instead-of-two.md)
  — closed in favour of [Whether article's last job can be done
  structurally](tickets/044-articles-last-job-structurally.md), after measuring
  the premise it turned on. moonofalabama's comment thread *is* a structural
  signature: 100 of `#content`'s 106 children are comments holding 90% of the
  text, 81 sharing an internal shape exactly, and the post is the one child whose
  shape occurs once — separable without reading a character count, so 011's
  objection does not reach it. What did not survive was the frame: this ticket
  permitted only "one mode" or "a port after all", and the live answers are in
  between — a strip pass beside the walker, or a trafilatura reduced to the one
  thing it still wins at.

- [Whether article's last job can be done structurally](tickets/044-articles-last-job-structurally.md)
  — it can, and `article` keeps its job anyway. The comment/post separation 025
  called uncomputable is computable from structure rather than text, so 011 is
  untouched and 025's step from "not from the text" to "therefore `article`" is
  what falls. But `article` already reads that page correctly, so the capability
  worth having is elsewhere: `dom` fidelity *minus* a run. A `drop_run` flag on
  `dom` taking a selector, only ever dropping runs the caller named, named for
  the mechanism and never for "discussion"; `article` and trafilatura untouched
  until a measurement that needs the flag. The false positive that was going to
  decide it was designed away rather than measured, the same move 021 made on
  `auto`.

- [Retire fetch: a tab and a script, and extraction becomes the agent's](tickets/046-retire-fetch.md)
  — `fetch` goes and `script` is the only door, which is 004's "one door with
  `page` bound" finally applied to the tool that predates it. Extraction is a
  judgement and judgement is the caller's: six mechanisms have been deleted for
  crossing that line and the two extractors that stayed are still failing. The
  measurements are not extraction and survive on the script result, `char_count`
  becomes the browser's own `innerText` length — which fixes 039 for free — and
  the walker moves to `skills/using-passenger/walker.js`, one tested copy with no
  production caller. trafilatura leaves, and with it most of what made the C#
  port expensive. The CLI loses `fetch` too, symmetry chosen over a human's
  convenience.

- [Delete fetch, and make script the only door](tickets/047-one-door-script.md)
  — done, −239 lines. `fetch`, both extractors, `mode`, `read(page)` and
  trafilatura are gone; `script` navigates, drives and measures, and reading a
  page is the caller's, with the walker shipped as
  `skills/using-passenger/walker.js`. `tidy()` moved into the walker, so the
  walker is the whole contract. `Fetched` became `Measured`, and `char_count` is
  the browser's own `innerText` length — which closed 039 by construction.
  `show_browser` gained `until="unblocked"`, the one thing `fetch` could do that
  nothing else reached.

- [A tab waiting on a server that never answers hangs every attach](tickets/042-attach-hangs-on-pending-navigation.md)
  — there are two wedges, wearing opposite symptoms, and 012 knew one. Its tab is
  *silent*: it holds a document and answers nothing. This one is *uncommitted*:
  it answers in under 10ms and holds no document at all. Measured: a tab that has
  committed never hangs the attach however slowly the rest arrives, so only the
  window before the first response byte matters; inside it a dead server and a
  slow one are the same state and nothing separates them. The empty frame URL is
  what separates a pre-commit tab from a healthy one — `about:blank` is a
  document, `""` is the absence of one. `Page.stopLoading` answers `{}` on such a
  tab and frees nothing; navigating it to `about:blank` frees it and keeps the
  tab, costing nothing because there is no document to lose. The attach message
  now says what was *checked* rather than asserting the negative, and `status`
  carries `wedged:` on both doors — a count per wedge, following 040.

- [Whether this moves to C#](tickets/023-rewriting-into-csharp.md)
  — yes, and it is built: `dotnet/` beside `passenger/`, both suites green, the
  Python still the daily driver. Not F#: Fable was F#'s whole advantage and it
  buys the walker being written in the tool's language, but the walker is a
  recipe the *caller* runs, so that unifies two things 046 deliberately
  separated — and at the door that matters, `script` on Roslyn, C# is what
  measurement 3 tested 3/3. **walker.js is untouched.** The port was affordable
  only because 047 deleted extraction first, which was priced here at twice the
  size of the program. The three owed measurements are discharged: packaging
  went moot with Fable, the MCP server serves all ten tools over stdio with
  bounds in the schema (measurement 2 had tested one), and System.CommandLine
  replaces cyclopts at more lines for the same contract — which makes 026
  slightly worse, not better. Verified against a real browser including both of
  042's wedges, each detected, distinguished and freed. The port's real tax is
  two seams C# needs that Python did not, both at a process boundary. Left: the
  flake does not build it, and 049 — the skill still teaches the Python door.

- [The skill teaches a door that no longer exists](tickets/049-skill-for-the-csharp-door.md)
  — two skills, and the tool list is the discriminator: the C# door's verbs are
  camelCase and the Python door's are snake_case, so an agent can tell before
  the first call. Both now open with **Which door you are at** pointing at the
  other. One skill carrying both spellings would double every recipe (026's
  drift); two doubles every non-code paragraph instead, which is the same drift
  moved rather than removed, and bounded by the overlap. Measured what the
  ticket asked rather than assuming it: a Roslyn compile is **flat** at ~40ms —
  an 11 KB source carrying the whole walker compiles as fast as a one-liner —
  so it cancels out of the skill's cost ordering, which stands. The 684ms first
  compile is what `Script.Warm()` exists for. walker.js is copied byte-identical
  and must stay so; it runs in the page, so neither language has a claim on it
  (030 holding as predicted). Porting it by *running* every recipe rather than
  translating found a live bug the green suite had missed: `IAPIResponse` was
  not in `Crossable`'s hand-written list of eight handles, so returning one
  serialised the driver's headers and timings as if they were the answer. A
  handle is now anything implementing a `Microsoft.Playwright` interface.

- [Delete the Python door](tickets/053-delete-the-python-door.md) — on direct
  instruction, not on 023's own bar of a couple of weeks of daily use; that
  measurement was never taken. `passenger/`, its suite, `pyproject.toml` and
  every Python-only Nix derivation are gone, `skills/using-passenger-csharp`
  took the deleted Python skill's old address, and `dotnet/src`, `dotnet/tests` and
  the rest moved to the repository root — there is nothing left for `dotnet/`
  to be a namespace *beside*. Closes
  [050](tickets/050-csharp-door-names-the-python-skill.md) by construction: the
  server's four strings already said `using-passenger`, and renaming the
  surviving skill to that address makes them correct without touching them.
  The walker recipe stopped pasting `walker.js` into a raw string literal and
  reads it from disk instead, since the server runs on the caller's own
  machine — which makes
  [052](tickets/052-walker-escapes-do-not-survive-transport.md)'s hazard
  unreachable at that call site without waiting on a fix to the file itself.
  Building the flake's package for the first time (`buildDotnetModule`, a
  locked `deps.json`, `Patchright`'s bundled Node symlinked to nixpkgs' own
  node the same way the deleted `nix/patchright.nix` did for Python) discharged 023's
  last owed item and, by running the suite somewhere `/bin` does not exist,
  found `SessionTests.cs` assumed it anyway.

- [The C# door sends its caller to the Python skill](tickets/050-csharp-door-names-the-python-skill.md)
  — closed by construction rather than by the find-and-replace it proposed:
  [053](tickets/053-delete-the-python-door.md) renamed the surviving skill to
  `using-passenger`, which is the address the server's four strings already
  named. What was live in it outlived it — the three facts every eval agent had
  to guess are in the fog entry below, and only the first (a script shares the
  caller's filesystem) has since been written into the skill.

- [Move the picture measurement to the caller](tickets/048-pictures-on-demand.md)
  — yes, and the envelope goes whole: `Measured` is deleted, not trimmed, so a
  `script` reply carries what the script returned and nothing else. 017's
  finding is not refuted but *declined* — the tool tells a caller nothing it did
  not ask for, and a page whose content is a photograph now reads as short to
  anyone who did not think to measure it. `pictures.js` ships to the skill
  beside `walker.js`, threshold and all, on `walker.js`'s own precedent for
  defaults following the file. The CLI loses its `N chars on URL` line rather
  than recomputing it, which is 046's symmetry trade taken again. Grilling the
  rule for coherence found it would eat the wall probe too; that was taken all
  the way and brought back, because `showBrowser(until="unblocked")` polls the
  same fixed table and a copy of it in a skill is what 019 and 038 made it
  single to prevent — so `blocked` stays default-on with a `checkWall` opt-out,
  and `page` gains an `unchecked` variant so a negative nobody tested cannot
  read like one that was (042). Built as
  [055](tickets/055-envelope-goes-the-caller-measures.md).

- [Delete the Measured envelope, and ship pictures.js to the
  skill](tickets/055-envelope-goes-the-caller-measures.md) — built, 86 green,
  and verified against the running browser. `Measured`, `Pictures` and
  `PicturesJs` are gone; a `script` reply carries what the script returned and
  `page`, which is a wall or `unchecked`. `pictures.js` sits beside `walker.js`
  in the skill with its threshold inside it. Running the recipes rather than
  reading them found the thing reading them could not: `System.IO` was never in
  `Script.cs`'s import list, so `File.ReadAllTextAsync` did not compile — which
  means the read-the-walker-off-disk recipe 053 shipped, and the
  `File.WriteAllBytesAsync` advice beside it, had never worked. Second time a
  recipe has been found broken by running it after passing review by reading it
  (049 was the first). Also found: Playwright deserialises with reference
  handling on, so a `JsonElement` returned straight back carries a phantom
  `$id`.

- [script's return value should be JSON, not another wrapping
  layer](tickets/054-script-return-should-be-json.md) — the envelope stays.
  `returned` keeps its slot and its name, and option 1's field-fusing was not
  what the complaint was about: checked against real replies, the thing that
  actually costs is a *string* payload, which has no fields to fuse. A page read
  arrives JSON-escaped onto one line with the whole page in the caller's
  context. The remedy was already in the skill under another heading — the
  server runs on the caller's own filesystem — so the recipe writes the markdown
  out and returns the path. Measured on PEP 8: 45,389 characters in a ~250-byte
  reply, 1,061 real lines on disk. The write belongs to the C# around
  `walker.js`, not to the walker, which runs in the page and has no filesystem.
  No code changed at either door.

- [The wire escapes non-ASCII to `\u`, six bytes where UTF-8 spends
  three](tickets/056-utf8-escape-regression.md) — closed twice. First without a
  code change: the escaping happens in the JSON-RPC envelope, which
  `ModelContextProtocol` 2.2.0 writes through a frozen `DefaultOptions` no
  caller can reach, and reflection at the `readonly static` behind it throws.
  Then reopened the same day on its own stated condition — the SDK grew the
  hook, in a fork
  ([glyh/csharp-sdk@utf8-wire-encoding](https://github.com/glyh/csharp-sdk/tree/utf8-wire-encoding)),
  adding `McpServerOptions.JsonSerializerOptions` that the stdio transport
  reads. `Program.cs` sets `UnsafeRelaxedJsonEscaping` and the wire now carries
  literal `腾冲`, zero `\u` sequences, verified by raw JSON-RPC probe against
  the built server. That took two goes: a reply is written *twice* -- the tool's
  return value into a JSON document inside a content block, with the tool
  registration's options, and then the envelope around it with the server's --
  so either one alone re-escapes what the other emitted, and the first probe
  passed only because an error reply has no inner document to escape. The dependency reaches the build as nupkgs the flake packs
  from a pinned source input and hands to restore as a local source, versioned
  `2.2.0-utf8wire.1` so it cannot be mistaken for the published 2.2.0; the two
  traps in that route — a hand-run `dotnet` has no offline source, and nixpkgs
  rewrites packed nupkgs down to a metadata-only stub — are written up in the
  ticket. Accepted knowingly: the relaxed encoder passes U+2028/U+2029 through,
  which is 052's hazard from a different direction, and the sentence about it
  in the `using-passenger` skill is not yet written.

- [`markdown.js` carries backslash-u escapes that do not survive
  transcription](tickets/052-walker-escapes-do-not-survive-transport.md) — fixed
  at the source, which is all that was left of the ticket after 053. The two
  regex literals in `tidy()` are now `new RegExp` over strings whose backslashes
  are doubled, so a JSON decode gives back the escape rather than the U+2028 it
  names and no literal ends early. Byte-identical output on four real pages,
  PEP 8 among them at the same 45,389 characters 051 recorded. The file is still
  not paste-safe and this never claimed to make it so: seven other backslashes
  remain, and a strict transcriber is rejected at the first `/\s+/` on line 113,
  before it ever reaches what was fixed. The difference is that those fail loudly
  at the boundary while the backslash-u pair failed silently, handing the page
  something that still looked like JavaScript. Chasing the rest was ruled out on
  the day rather than deferred: the file is best-effort by design, a recipe an
  agent reads off disk and is expected to tweak, so paying the literalness that
  makes it readable for fidelity on a path nobody is asked to take is the wrong
  trade. The skill now says that outright — *It is a recipe, not an API* — and
  its pasting paragraph stayed and changed its grounds: reading still beats
  pasting, for the general reason now.

- [The walker strips `aside`, and `aside` carries
  footnotes](tickets/051-walker-strips-asides.md) — fixed by a fourth option the
  ticket did not list. Not 1 (narrow the strip list), not 2 (drop `aside`), not 3
  (document the flag), but a separate opt-in pre-pass,
  `skills/using-passenger/unstrip-asides.js`, run in the page before
  `markdown.js`: it retags content-bearing asides as `section` so the strip list
  stops matching them, and returns a count. Both of `aside`'s jobs are real —
  the HTML standard names sidebars and advertising, docutils 0.18 emits
  footnotes — so the strip list stays one global answer and the disagreement
  moves to the call site, on the pages where it is true. Measured: PEP 8 45,389
  → 46,122 characters, links 20 → 23, `## References` populated, and
  **byte-identical to running `markdown.js` with `aside` removed from its strip
  list**, so it gives up nothing against option 2 while leaving option 2's
  furniture problem untaken. Nothing rescued and nothing changed on
  theguardian.com's 22 asides, numpy's Sphinx pages, Wikipedia or the Python
  docs; idempotent on a second run. The container half of the selector is
  load-bearing rather than defensive: docutils 0.19 wraps groups of footnotes in
  an outer role-less `aside` and the walk skips a subtree at the outermost one
  it meets. The skill gained the third failure shape 051 asked for — it strips a
  fixed list of furniture and something carrying content can be on it, invisibly
  to the character count. Still no test: verified by running it, like everything
  else about this file (043).
  Two things worth carrying forward: the first draft of the explanatory comment
  broke the file by spelling a bare U+2028 in prose, so the file's rule is that
  nothing in it may spell one, comments included; and the test-shaped property is
  *not* "survives a JSON round trip" — that is the identity function — but "no
  backslash escape whose JSON reading differs from its JavaScript one", which is
  an assertion over bytes and needs no browser.

- [One description, two doors](tickets/026-one-description-two-doors.md) —
  closed by subtraction: there is no second door. Grilling it started from the
  question the ticket never asked, who uses the CLI, and the answer is nobody —
  never run by the owner, invoked by no test, named in no skill, and the warm
  profile it exists for was logged in through the MCP door. Both of the ticket's
  own counts were wrong on the way out: six verbs overlapped rather than two
  (the names differ, not the behaviour), and the drift ran *both* ways, with
  `status` and `browserStatus` disagreeing in each direction at once. Every
  difference but one followed a statable rule — the CLI's extras served a human
  at a terminal, MCP's reached a human who is not the caller (018) — and the
  exception, `until="unblocked"`, is moot with the door gone. Recorded for reuse:
  the alternative to a generator was a conformance test that subtracts the two
  parameter lists and fails unless each difference is declared beside its reason,
  which is the ticket's own goal for forty lines. It needed two doors. See
  [Delete the CLI door](tickets/057-delete-the-cli.md).

- [Delete the CLI door](tickets/057-delete-the-cli.md) — done. `src/Passenger.Cli`
  and System.CommandLine are gone; `stop` survives alone as a verb on
  `Passenger.Mcp`, handled beside the viewer re-exec before the host is built,
  refusing while a lane holds the screen or owns live tabs unless `--force`. One
  binary, one app: `apps.mcp` was removed rather than aliased, so a registration
  saying `#mcp` must lose it. The reserved `cli` lane went with the terminal it
  was for. Two things the plan had wrong, both found by running it: refusing on
  `ScreenClaims()` alone would have wedged the one command that clears a wedge,
  since claim rows outlive a dead Chrome — both halves are gated on
  `Browser.IsUp()` now. And `PassengerException` kept `Detail` out of `Message`
  while `Tools.cs` caught nothing, so **every remedy string this project has
  written, 042's stuck-lane list included, had never once reached an agent**. One
  line in the constructor, not the catch block the ticket proposed. Closes
  [026](tickets/026-one-description-two-doors.md). 89 green.

## Fog

- **A picture measurement can be fooled from both ends.** 017 reports the
  largest visible picture as a share of the viewport, and took two costs
  knowingly. A full-window cookie-consent `iframe` reads 0.99 on theguardian,
  and the filters that would catch it are either same-origin-only -- which
  excludes the Vimeo embed that *is* apod.nasa.gov -- or the vendor table 019
  deleted. In the other direction xkcd 2001's comic is 0.06, because a small
  picture can still be the whole content, and viewport geometry cannot see
  that; `char_count` beside it is what the caller reads instead. There is also
  a cold-cache artifact: an unloaded `<img>` that sizes its own box measures
  zero, so a first visit can under-report where a second does not. Whether any
  of these is worth a mechanism, or whether the caller judging from
  `largest_image_src` and `char_count` is the whole answer, is unexamined.

- **A headless MCP deployment may have no way to reach a human.** 018 made
  notifying an explicit choice, which is right, but `notify.select()` fans out
  to stderr, `notify-send` and a webhook — and on the MCP door stderr is the
  server's log, which nobody reads, while `notify-send` needs a desktop. So a
  container with no `PASSENGER_WEBHOOK` set can be told to summon a human
  and reach nobody, then block for the full wait. Whether the tool should say
  so when asked to notify with nothing that can, or whether that is the
  deployment's problem, is unexamined.

- **The C# port itself, once it is a go.** [Whether this moves to
  C#](tickets/023-rewriting-into-csharp.md) decides *whether*, and the
  grilling behind it already fixed the shape: built alongside the Python
  one in this repo, Python deleted on a couple of weeks of daily use
  rather than a green test run, and only after 021 and 022 have landed —
  025 now has. The build is far larger than one session, so it is not yet
  sliced into tickets. Its second phase has fired: 025 kept `article`, so
  something in C# has to do what trafilatura does. How large that is is
  [One extractor instead of
  two](tickets/029-one-extractor-instead-of-two.md) — reimplement rather
  than port, strong enough that one mode suffices. Where the *walk* runs is
  settled, and it costs the port nothing: it stays JavaScript evaluated in the page,
  which `Runtime.evaluate` reaches from C# exactly as from Python, so it is
  the one piece of `extract.py` that crosses unchanged. The `DOMSnapshot`
  rewrite that would have replaced it was weighed and refused — see [The
  walker reads a snapshot, not the
  page](tickets/030-the-walker-reads-a-snapshot.md).

- **A page can defer content and say nothing.** A page that withholds content
  usually says so, and 016 decided the agent should be the one to notice. But
  the xiaohongshu listing — 22 notes where 619 exist —
  carries no marker at all, and neither does a plain infinite scroller; both
  are reachable by `script` and invisible to anything cheaper. Scrolling once
  and measuring whether the document grew *does* catch them (+51% and +214%
  against six unmoved controls), and was rejected as a default rather than as
  an idea. Whether it comes back as an opt-in, and whether anything short of
  driving the page can see a silent deferral, is unexamined.
- **Two viewers fight over the framebuffer.** Now that the size is
  client-driven, every connected viewer asks for its own window's size,
  and the last to ask wins. Harmless with one viewer, which is the only
  case exercised; unclear what the right behaviour even is with two.
- **The `web` presenter is exercised only on this machine.** It is the
  same page and server the local presenter uses, so the path is no longer
  untested — but nothing has yet opened it from another machine, which is
  the case it exists for, and wayvnc's websocket is bound to localhost.
- **Pid reuse.** The session record trusts pids. Across a reboot, or
  after enough churn, a recorded pid could belong to something else
  entirely -- and `teardown` would SIGTERM it. A start time or cgroup
  check would pin identity properly. Unclear yet whether this is a real
  risk or a theoretical one. 024 met the other side of it: a pid that
  survives SIGKILL is most likely one that was never ours, and teardown now
  keeps the record and says so rather than signalling further.
- **One browser at a time is assumed everywhere.** The CDP port, the
  profile directory, and the session record are all single-valued. If
  concurrent sessions are ever wanted, that assumption is load-bearing
  in more places than it looks.
- **A long-running MCP server can hold stale code.** Editing `passenger/` does
  not affect an already-running server, which is confusing precisely
  when someone is mid-debugging. Perhaps a version report in
  `browser_status`; perhaps nothing. One branch is closed: nothing gets made
  hot-reloadable to paper over it. 034 weighed reading `walker.js` per call
  and refused — it would make *which code ran* unanswerable, which is worse
  than stale. The standing expectation is that a server is restarted after an
  edit; what is unresolved is only whether it should be able to say so.
- **Input quality during handoff, not just output.** The pointer is now
  drawn and singular, but keyboard layout, clipboard, and IME through the
  VNC path are still unexamined -- a login the human cannot type into
  fails just as hard as one they cannot see.
- **Two Wayland operations shell out to CLI tools.** `wlr-randr` sets the
  output size and `wayland-info` reads the screen. Both are protocol
  operations that a binding could do in-process, but no Python library
  speaks wlr-output-management, and generating bindings for it would be a
  large dependency for a small tool. Worth revisiting if the parsing of
  either tool's human-readable output ever bites.
- **A fetch returns the whole page, and nothing bounds it.** For an
  agent, the page *is* the context budget: a listing of a hundred
  bankruptcy notices costs the same as the paragraph that mattered.
  There is no cap, no selector to scope the read, and no notice when
  something was long — one Hacker News thread measured 462,337 characters
  from a single fetch. Paging such a list a few times is enough to feel
  it, and links made it sharper: a listing now costs several times what it
  did, for pointers that are the point. Whether the answer is a `max_words`,
  a scoping selector, or simply leaving it to the caller is unexamined --
  but it interacts with
  [Reaching content that sits behind an interaction](tickets/004-driving-the-page.md),
  where a read-per-step multiplies the cost.
- **Nothing notices a session dying mid-fetch.** `reap_stale` runs at
  start. A crash between fetches is only discovered on the next one. The tab
  half of this is answered; a Chrome that died between fetches, or a compositor
  that outlived it, is still unexamined. The reporting half is answered as far
  as it goes: `status` and `browser_status` now carry a tab count (040). It is
  a count and not a listing on purpose, so it says that tabs are piling up
  without saying whose.

- **An agent treats the document in front of it as the whole procedure.**
  What 032 could not fix, and may not be this repo's to fix. The six copied
  paragraphs were written by an agent that had the server instructions and
  `show_browser`'s docstring in context at the time; being the proximate
  authority is what made the skill win. One skill for this server makes the
  document in front of it the right one, which is a remedy for this instance
  and not for the shape.

- **An extraction that came back empty cannot say so.** 039 closed without
  building it. The tool measures a page and hands back `char_count`, and when the
  extractor finds nothing in a document that has something, that zero is a
  measurement of this side wearing the page's clothes -- and `article`'s
  half-filled table is the same admission, harder to see. It needs no phrase
  table and no language list, only a comparison of two numbers already in hand,
  which is what separates it from the four heuristics that were deleted for
  ruling on meaning. What is missing is not a design but a second instance: one
  site is not a class, and the probe that would settle it was never run.

- **A read can lose a page's reference apparatus inside the noise floor.** The
  walker strips `aside`, and docutils and Sphinx emit footnotes as
  `<aside class="footnote">`. On PEP 8 that is a populated `## References`
  reduced to an empty heading and three absolute links gone, for an **18
  character** shortfall against `char_count` -- 0.04% of the body. 039's fog
  entry above is about an extraction that came back empty and cannot say so;
  this is the same shape at the other end of the scale, where the extraction
  came back 99.96% full and cannot say what the missing 0.04% was carrying. The
  comparison of two numbers already in hand does not reach it. See [The walker
  strips aside, and aside carries
  footnotes](tickets/051-walker-strips-asides.md).

- **Two skills, and no measurable difference between having one and not.**
  Twelve runs -- three tasks across both doors, with and without the skill --
  logging every `script` call and its error code. All twelve produced correct
  output. Eight -- the image and the HN tasks, every condition -- finished in
  one or two calls with zero errors, with or without a skill, and the image
  outputs were byte-identical across all four conditions. The only failed calls
  in the whole run belonged to a *with-skill* run, spent on the shipped walker
  (052). Agents reasoned their way
  unaided to the two things the C# skill claims as its own (`BodyAsync()` rather
  than the response; bytes cannot cross, so write from inside the script), and
  the `script` schema already carries the PascalCase-async convention and the
  JSON-only return rule that three of the C# skill's seven extra blocks restate.
  What the runs *did* surface was three facts neither skill states and every
  agent had to guess: whether a script shares the caller's filesystem (it does,
  and knowing it upfront halves the image task), that `largest_image`'s `src`
  can name a different asset than the `<img src>` a reader sees, and the walker
  entry above. The unexamined question is whether either skill is earning its
  context -- on the one task that cost anyone a failed call, the shipped recipe
  was the cause and both no-skill runs, writing their own extractor, did no
  worse -- or whether what is load-bearing in them belongs in the tool schemas
  that 032's fog entry says an agent reads anyway.
