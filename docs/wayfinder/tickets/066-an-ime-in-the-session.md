---
id: 066
title: The session runs the host's own IME
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

A human handed the browser could not type Chinese into it. On a machine whose
owner reads and writes Chinese all day, that is not a rough edge on the handoff
-- it is the handoff failing at the moment it is needed, since the login being
finished by hand is as likely to want 中文 as anything else.

[062](062-across-the-vnc-boundary.md) named the cause and stopped there: nothing
in the session composes, and no IME could attach because cage offered no
`text-input` or `input-method` protocol for one to attach *to*. That answer was
correct when it was written and stale within the hour --
[063](063-sway-instead-of-cage.md) swapped the compositor, and sway advertises
both.

So the question this ticket asked: with the protocols present, what does it take
to have an IME in there -- and can it be the human's own, rather than some
default nobody chose?

## Answer

*Closed 2026-08-25.* It takes a daemon, and it can be theirs.

Chrome needed no argument at all: it already speaks the protocol, so the entire
missing piece was that no process in the session was *being* an input method.
Spiked by hand against the live session first -- fcitx5 attached, pinyin loaded,
and the owner typed into the nested browser and called it usable -- then built.

**It is the human's own fcitx5, and not a second one.** The first version ran a
private instance on a private bus against a copy of `~/.config/fcitx5`, and the
owner asked the question that killed it: *why can't we reuse the same fcitx
program?* We can. fcitx5's controller exposes `OpenWaylandConnection` for
precisely this -- one process serving several compositors -- so the session
script makes one D-Bus call and the running instance attaches to the nested
display:

    Group [wayland:]          has 3 InputContext(s)     <- the desktop
    Group [wayland:wayland-2] has 1 InputContext(s)     <- the session

That is the real config, the real learned dictionary and this morning's changes,
live rather than copied. It disposes of the private bus, the copy, and the
copy's own bug: `~/.config/fcitx5` here is a symlink into a dotfiles repo, and
`cp -r` copied the link, so the isolation the first version advertised pointed
straight back at the original. `dbus` stays in the closure for `dbus-send` and
nothing else.

`PASSENGER_IME=none` asks for no IME; an fcitx5 that is not running answers the
call with an error, which the session log now records. Either way the session
cannot compose, which is what every session was until today, and pasting is the
route.

**Nothing to tear down.** fcitx5 drops the connection when the display goes
away.

## What the first attempt cost, and paid for

It was tried, packaged, and did not work -- and the failure was invisible,
because the session script sent everything to `/dev/null`. A wayvnc that cannot
bind ([064](064-wayvnc-socket-path-too-long.md)) and a compositor that refuses
to exit both look exactly like a healthy session from outside. So the script now
writes `{state}/session.log`, truncated per start, carrying its own account and
its children's; and its teardown says which half failed rather than trying two
things silently.

That log exists because of this ticket, and it belongs to 064's second half.

## What moved beside it

The templates stopped being string literals. `session.sh`, `ime.sh` and
`sway.conf` are files under `Assets/session/`, embedded the way `viewer.html`
already was, so a shell script can be highlighted, diffed and linted as one
instead of living inside a C# raw string. `Assets.Read` is the one reader, now
shared with `Webserve`.

Two comments bit back while this landed, both worth the retelling. The IME
snippet's own comment contained `{ime}`, so substitution rewrote the prose. And
the sway config's comment said "a test asserts there is no bindsym in this
file", which the test then found -- so the check now reads directives and
ignores comments, which is what it should have done from the start.
