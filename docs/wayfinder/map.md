---
labels: [wayfinder:map]
---

# Making the nested browser stack trustworthy

## Notes

**Domain.** `agent-browser` fetches pages through a real, logged-in
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
  `ab/walker.js` — 224 lines of `extract.py` down to 115, closures given
  names, no seam and no JavaScript runner — verified byte-identical against
  ten fixtures. Read once at import, which also made `pythonImportsCheck`
  catch the file missing from the wheel, as it promptly did.

## Fog

- **A headless MCP deployment may have no way to reach a human.** 018 made
  notifying an explicit choice, which is right, but `notify.select()` fans out
  to stderr, `notify-send` and a webhook — and on the MCP door stderr is the
  server's log, which nobody reads, while `notify-send` needs a desktop. So a
  container with no `AGENT_BROWSER_WEBHOOK` set can be told to summon a human
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
- **A long-running MCP server can hold stale code.** Editing `ab/` does
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
  that outlived it, is still unexamined -- as is the fact that nothing reports
  what tabs are open until something goes wrong.
