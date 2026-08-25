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

**The binary is the host's**, found on PATH, exactly like the browser and for
the same reason ticket 023 gives: an input method is a person's configuration,
dictionaries and habits, and pinning one in the closure would hand them somebody
else's keyboard. `PASSENGER_IME` names it, defaults to `fcitx5`, and `none`
turns it off. No fcitx5 on the machine is not an error -- it is a session that
cannot compose, which is what every session was until today.

**It runs on a private D-Bus.** fcitx5 claims `org.fcitx.Fcitx5` on the session
bus, and the human's desktop is almost certainly already running one -- here it
was pid 8996. Two instances on one bus is a fight over the name, so the session's
gets its own via `dbus-run-session`, and the desktop's is never disturbed. That
is why `dbus` joins the closure.

**It runs against a copy of the config,** refreshed at every start.
`XDG_CONFIG_HOME` points at `{state}/ime`, into which `~/.config/fcitx5` is
copied. The dictionaries, layouts and pinyin settings come along; the running
desktop's profile is never written to, because two fcitx5 instances sharing one
config directory would write over each other's state. The deliberate cost: a
setting changed *inside* the session does not persist. That is the right way
round for a tool that [does not learn](019-the-tool-does-not-learn.md) -- the
durable copy stays the human's, on their desktop, where they can see it.

**It dies with the browser.** The session script kills it after `wait
"$chrome_pid"`, and it would go anyway as a Wayland client when the compositor
exits; the explicit kill is the belt to that pair of braces.

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
