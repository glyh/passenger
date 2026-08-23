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
  — say it from the text already returned. The page prints `共 153 条评论` and
  five `展开 N 条回复`, and the extraction already contains every one of them,
  so the hedge is a pure function over a string this project produced rather
  than a second look at the page. Numbered markers only: bare "load more" is
  furniture on the Rust blog and on BBC. Scrolling once to see whether the page
  grew was rejected — it points at the wrong content on a note, and it makes
  every read a driving act.

- [The extract mode decides whether a page counts as blocked](tickets/005-mode-decides-blocked.md)
  — the tier is gone, not fixed. A signature match is a positive claim made from
  things the caller cannot see; a word count under `min_words` was the tool
  ruling on a number it hands over anyway. `classify` is one dumb tier now, and
  the guessing that hung off the other one — evidence capture, proposed
  signatures, `registry.remember` — went with it. The registry's curation half
  stayed.
- [A fetch of an ordinary page put the browser on screen and waited](tickets/010-fetch-seizes-the-screen.md)
  — closed by 005, from the other end. The handoff is reached only on a
  signature match, so the strongest action the tool has is triggered only by its
  strongest evidence. `fetch https://example.com` returns thirty-odd words and
  exits 0.

## Fog

- **A page can defer content and say nothing.** 015's signal only speaks
  when the page does. The xiaohongshu listing — 22 notes where 619 exist —
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
  risk or a theoretical one.
- **One browser at a time is assumed everywhere.** The CDP port, the
  profile directory, and the session record are all single-valued. If
  concurrent sessions are ever wanted, that assumption is load-bearing
  in more places than it looks.
- **A long-running MCP server can hold stale code.** Editing `ab/` does
  not affect an already-running server, which is confusing precisely
  when someone is mid-debugging. Perhaps a version report in
  `browser_status`; perhaps nothing.
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
