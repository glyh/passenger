---
id: 059
title: The visible-window fallback no caller can reach
labels: [wayfinder:research]
status: open
assignee: lyh (via Claude)
blocked_by: []
---

## Question

`PASSENGER_WM=none` is documented as a fallback -- `README.md`'s launch table
says "no-op — fallback when cage/wayvnc are missing — the window stays
visible". No caller can reach it. Under that backend the daemon cannot start at
all, and the error it raises names a flag that ticket
[057](057-delete-the-cli.md) deleted.

The guard is `Browser.cs:89`: start refuses when the backend is `None` *and*
the start is hidden, which is right -- silently putting a visible Chrome on
someone's screen would defeat the tool, and the caller would never know. But
the only call site in the tree passes `hidden: true` unconditionally
(`Tools.cs:54`), and no MCP tool takes an argument that would change it.
`StartAsync`'s `hidden` parameter has had exactly one possible value since the
CLI went. So the condition is not a guard on a choice; it is a guard on a
constant, and it fires every time.

What the caller gets back is `CannotHide`, whose second remedy is "or start it
with `--visible` to accept a visible window" (`Browser.cs:96`). `--visible` was
a CLI flag. 057 rewrote three such strings in core and missed this one, which
is the fault that ticket was named after: the remedies nobody read.

So on a machine without cage and wayvnc, `passenger` has no working
configuration, and says so by pointing at a command that does not exist.

## What is actually being asked

Whether an agent may accept a visible window.

057 settled the neighbouring question in the other direction -- destructive
things a human should own do not get an agent tool, which is why `stop` is
typed rather than called. This is not destructive, but it is the same shape:
the action costs the *human* something (their screen, and the illusion that
nothing is driving their desktop) while the agent is the one who benefits from
proceeding. The `NoOpBackend` comment calls itself "a null object for when its
dependencies are missing"; a null object nothing can select is dead code
wearing a fallback's name.

Three answers, and the ticket is which one:

- **Delete `none`.** `AutoOrder` (`Launch.cs:129`) loses its second entry,
  `PASSENGER_WM` loses a value, and the README's table loses a row. The
  refusal moves earlier and gets honest: cage and wayvnc are requirements, not
  preferences, and a machine without them cannot run this. Cheapest, and it
  matches what is true today.
- **Make it reachable.** Something -- an env var, since a tool argument would
  let an agent take the screen without a human ever agreeing -- says "I accept
  a visible window", and `hidden` becomes a real parameter again. This is the
  only answer that makes the README's fallback sentence true, and it wants a
  hard look at what a visible Chrome does to the rest of the design: the
  handoff (`Present`) assumes a window the human cannot already see, and
  `showBrowser`'s whole contract is that summoning is an event.
- **Keep it dead, fix the string.** Delete the `--visible` clause and leave
  `none` selectable-but-fatal, so the error explains the real requirement.
  Honest, one line, and leaves a backend that exists only to produce a better
  error message.

Whichever wins, the README's launch table is wrong until it lands.

## Where this came from

Noticed while answering whether the nix closure could be vendored as a single
artifact for arbitrary Linux machines. It bears on that: cage and wayvnc are
~800 MiB of the 896 MiB closure, and the obvious saving is to drop them and
lean on the documented fallback. There is no fallback to lean on.

Not in scope here, but adjacent and worth its own ticket if anyone wants it:
headless is refused for good reasons (`Launch.cs:1` -- fingerprint, and no
human handoff), so "runs anywhere" has a floor no packaging can lower. A DRM
render node and a host Chrome are requirements of the design, not of the
build.
