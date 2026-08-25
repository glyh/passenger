---
id: 067
title: An attached input method segfaults the nested Chrome
labels: [wayfinder:task]
status: open
assignee:
blocked_by: []
---

## Question

[066](066-an-ime-in-the-session.md) gave the session an IME and it works -- typed
into, by hand, in Chinese, before any of it was wired in. Wired in, it crashes
the browser.

Two trials through the shipped code path, fresh profile each, one variable apart:

    PASSENGER_IME=none      chrome survived 60s      segfaults in log: 0
    PASSENGER_IME=fcitx5    chrome DIED after ~0s    segfaults in log: 1

    session.sh: line 43: 1642099 Segmentation fault (core dumped)
      'google-chrome-stable' '--remote-debugging-port=9501' ... 'about:blank'

Chrome reaches `DevTools listening` first and dies a moment later, so it is not
a failure to start; something kills it once it is up.

**It is not about reusing the human's instance.** Attaching a *separate* fcitx5
on a private bus, to a session that had come up cleanly without one, crashed it
the same way. So the trigger is an input method being present on the display at
all, not which process provides it.

**And it did not always do this.** The hand-run spike that proved the idea had
fcitx5 attached to a live session for minutes while a human typed Chinese into
the nested browser. What differs between that and the trials is not yet known --
candidates are the moment of attach relative to Chrome's surfaces existing,
whether a page had focus, and whether the crash was simply not noticed then,
since the session had no log before 066 added one.

So: why does Chrome die, and can the IME be had without it?

## What is already known

- `--ozone-platform=wayland` and `--ozone-platform-hint=auto` reach the nested
  Chrome from the human's `~/.config/chrome-flags.conf`, not from this repo --
  see [061](061-chrome-platform-from-a-dotfile.md), which is still open. So the
  browser under test is speaking Wayland for a reason nothing here controls, and
  061 should probably close before this one is chased far.
- Chrome logs `'--ozone-platform=wayland' is not compatible with Vulkan` on every
  start, with or without an IME. Probably unrelated; recorded so the next person
  does not chase it twice.
- The crash is of the process the session script waits on, so the teardown fires
  correctly and takes the compositor with it -- which is why it presents as "the
  session vanished" rather than as a broken browser.

## Where to look

1. **The core dump.** It is a real segfault with `(core dumped)`; a backtrace
   naming the frame would answer the whole question, and nobody has looked yet.
2. **`--wayland-text-input-version`.** Chromium has taken text-input v1 and v3
   through several incompatible spellings; if it is negotiating a version fcitx5
   answers differently, that is both the bug and the fix.
3. **Timing.** Attach after a page has focus, rather than at session start --
   one trial did attach six seconds in and still crashed, but that page was
   `about:blank` with nothing focused.
4. **Another IME.** ibus speaks the same protocol; if it does not crash, the
   fault is fcitx5's side of it.

## Meanwhile

`PASSENGER_IME` defaults to `none`, and the whole mechanism is one D-Bus call
behind it. A browser that cannot compose is worse than one that can; a browser
that does not start is worse than both.
