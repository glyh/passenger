---
id: 020
title: How thin can this layer get
labels: [wayfinder:grilling]
status: open
assignee:
blocked_by: []
---

## Question

Eight tools cross the MCP boundary:

    fetch           goto, settle, read, classify -- and the handoff
    script          caller-supplied Python with `page` and `read(page)`
    list_tabs       CDP target list
    close_tabs      housekeeping after earlier fetches
    show_browser    put the nested browser on screen
    hide_browser    take it away again
    browser_status  daemon, presenter, session, vnc endpoint
    list_blockers   the signature table

[Reaching content that sits behind an
interaction](004-driving-the-page.md) decided not to add verbs: hand over
`page` itself and let the caller write Playwright, rather than wrapping
click, fill, select, wait and the rest. That decision was made about the
verbs that did not exist yet. This ticket asks it about the ones that
already did -- most of the list above predates `script`, and some of it
exists only because there was no other way in at the time.

The standing preference is that the agent does the work and this layer
stays as thin as it can be. So the question for each tool is not "is it
useful" -- they all are -- but "does it still need to be a *tool*".

Roughly in order of how much they look like surface rather than
capability:

1. **`list_blockers`.** Once [The tool does not learn; the agent
   remembers](019-the-tool-does-not-learn.md) lands, `registry.listing()`
   is a fixed table of eight vendor signatures that never changes between
   calls. A constant does not need a round trip: it could be a line in
   the `fetch` description, or an MCP *resource* rather than a tool.
   (Its current output also reports `pending_review`, which 019 deletes.)
2. **`show_browser` / `hide_browser`.** One toggle wearing two tools.
   `browser_status` already reports `on_screen`, so the pair could be a
   single call with an argument, or an argument on status.
3. **`close_tabs`.** Housekeeping a script can do, and `fetch` already
   does internally via its own `close_tabs`. Worth asking whether the
   caller should ever have to think about it, or whether tab hygiene is
   this layer's own business.
4. **`fetch` against `script`.** The hard one, and the one to be most
   careful about. `page.goto(url); return read(page)` is the whole of
   `fetch`, so on the "two ways to do one thing" principle this codebase
   keeps applying, `fetch` is the redundant one. Against that: it is the
   overwhelmingly common case, it costs the caller no code and no
   thought, and making an agent write three lines of Python to read a URL
   is a worse boundary even if it is a thinner one. Note `fetch` does
   hold one thing `script` does not -- `wait_seconds`, the handoff -- and
   [Asking for a human, rather than being guessed
   at](018-asking-for-a-human.md) may move that out from under it.

What must not be lost:

- **`list_tabs` has a reason `script` cannot cover.** It reads the CDP
  HTTP endpoint, served by the browser process, which keeps answering
  when a page's renderer does not -- that is the whole point of
  [One wedged tab bricks every later call](012-one-wedged-tab-bricks-every-call.md).
  A script needs a working tab to run in; listing must not.
- **`show`/`hide`/`status` are outside the page.** Nothing reachable
  from `page` can present a compositor or report whether a viewer is
  attached. However they are packaged, that capability is irreducible.

To decide:

1. Whether the measure of thinness is tool *count* or total schema
   text. Every tool's description is paid for in every session that
   loads the server, used or not, which is the real budget being spent.
2. Whether MCP resources are the right home for the things that are
   read-only and rarely change (the signature table, the status), so
   they stop occupying tool slots.
3. Whether `fetch` survives as a convenience over `script`, and if so,
   how that is squared with a codebase that keeps refusing second ways
   to do one thing. "It is the common case" is a real argument; it is
   also the argument every wrapper makes.
4. What the floor is. If the honest answer is `script` plus a presenter
   control plus a tab list, that is three tools, and worth saying out
   loud even if the conclusion is that it goes too far.

## Decided so far

**`list_blockers` is gone.** Eight tools are seven.

It was the easy one and it did not need to wait for
[The tool does not learn; the agent
remembers](019-the-tool-does-not-learn.md). Even today, with the learned
list emptied, what it returned was a table that does not change between
calls -- and the caller does not need it in advance, because the name of
whatever is in the way arrives *in the `blocked` record*, at the moment
it becomes relevant. Paying a tool slot in every session to enumerate
challenge vendors up front is the shape this ticket exists to find.

Nothing replaced it. The `signatures` CLI command still lists the table
for a human, which is who was ever going to read it as a list. If 019
lands and the table becomes a true constant, an MCP resource is still
available -- but a description line was not added on the way out, because
adding text to every session to explain a tool that was removed to save
text is the wrong trade.

The remaining questions stand. `show`/`hide`, `close_tabs` and the
`fetch`-against-`script` question are all still open, and the fourth --
what the floor is -- is the one worth answering deliberately rather than
by attrition.
