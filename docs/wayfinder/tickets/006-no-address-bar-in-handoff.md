---
id: 006
title: The human takes over a browser with no address bar
labels: [wayfinder:research]
status: closed
assignee: claude
blocked_by: []
---

## Question

What the viewer shows is a Chrome with no URL bar, no back button and no
tab strip -- just the page, edge to edge. A human handed this window can
click and type inside the page, and nothing else. They cannot see what
URL they are on, cannot go back out of a redirect, cannot open a second
tab to check a login, and cannot type an address.

Two chromeless layers are stacked here and only one of them is intended:

- The *host* window is chromeless on purpose. `_open` in `present.py`
  starts the host browser with `--app=`, and `web/viewer.html` says why:
  the window should look like the remote browser itself, not like a VNC
  client wrapped in one. Nothing wrong with that -- it is the frame, not
  the content.
- The *nested* Chrome appears to lose its own toolbar to `cage`, which
  fullscreens its client by design. Chrome in fullscreen hides the
  toolbar, so the browser the human is actually driving has no controls.
  This is a side effect of choosing a kiosk compositor to hide the
  window in, not a decision anyone made about the handoff.

Worth confirming the mechanism before designing around it -- it could
equally be that cage is not fullscreening and Chrome is starting that way
for another reason.

To decide:

1. **Whether the nested Chrome should show its toolbar at all.** The
   window is normally invisible, so the toolbar costs nothing except
   when someone is looking -- which is exactly when it is wanted. But it
   also eats framebuffer height that the page could have, and the
   framebuffer is sized to the viewer's window
   ([Sizing the cage output to the viewer's real window and
   scale](002-vnc-output-sizing.md)).
2. **How to get it back.** If cage's fullscreen is the cause, the options
   are a different nested compositor, a cage that can be told not to
   fullscreen, or leaving Chrome fullscreen and adding the missing
   affordances at the viewer layer instead.
3. **Whether the viewer page should carry the controls.** A URL readout
   and a back button in `viewer.html` would need the current URL and a
   way to act on it -- both available over CDP, which this side already
   speaks. That keeps the nested window untouched and puts the controls
   in the frame that was deliberately built for the human. It also means
   the handoff surface is ours to shape rather than Chrome's.
4. **What a human is allowed to do during a handoff.** Full browser
   controls mean they can navigate anywhere in the agent's logged-in
   profile. That is probably fine -- it is the user's own browser -- but
   it is a decision, and it bears on
   [Reaching content that sits behind an interaction](004-driving-the-page.md):
   if the human's navigation is how the agent reaches a page, then
   letting them navigate is the whole point, and reading back where they
   ended up becomes required rather than optional.

Related fog: **Input quality during handoff, not just output** on the
map. Keyboard, clipboard and IME are the same question asked about the
other half of the interaction -- a window you cannot navigate and a
window you cannot type into fail the handoff in the same way.

## Answer

The mechanism was the suspected one, confirmed by screenshotting the nested
compositor directly (`WAYLAND_DISPLAY=wayland-0 grim`): cage fullscreens its
client, Chrome hides its UI in fullscreen, and the frame contained the page
and nothing else.

`Browser.setWindowBounds` with `windowState: normal` is the whole fix. Chrome
reports `maximized` afterwards -- cage still owns the geometry, so the window
keeps filling the output -- and the tab strip, address bar, back button and
`+` all come back. cage does not fight it: the toolbar survived a
`wlr-randr --custom-mode` resize of the nested output, which is the same
event the viewer's `SetDesktopSize` produces, so the client-driven resize of
[Sizing the cage output to the viewer's real window and
scale](002-vnc-output-sizing.md) does not undo it.

So, against the questions:

1. **The nested Chrome keeps its toolbar, permanently** -- not toggled around
   the handoff. A toggle would have to be undone on dismiss, and would be
   wrong whenever a viewer died without dismissing. The cost is the toolbar's
   height off the page viewport, which is what a real browser costs too:
   fullscreen with no browser UI is the *less* ordinary shape for a window to
   be in, and `outerHeight == screen.height` with nothing accounting for the
   difference is a small fingerprint delta this now closes rather than opens.
2. **Neither a different compositor nor a patched cage was needed.** The
   window state was always ours to set over CDP, which this tool already
   speaks.
3. **The viewer page grows no controls.** `viewer.html` stays what it says it
   is -- the screen alone, edge to edge -- and the controls are Chrome's own,
   which no reimplementation would have matched.
4. **A human in a handoff can navigate anywhere in the profile.** That is the
   deliberate outcome: it is the user's own browser, and it is what makes the
   cheap half of [Reaching content that sits behind an
   interaction](004-driving-the-page.md) worth building -- a human who can
   type an address and search a site is only useful if this side can then
   read where they ended up.

Implemented as `browser.unfullscreen()`, called at daemon start and from
`present._prepared()` before every handoff. The second call is what fixes a
session that was already running, and costs one CDP attach on an operation a
human is waiting on anyway. It reads the state before writing, so `--visible`
and the no-op backend go through it untouched.
