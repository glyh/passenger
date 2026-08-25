---
id: 063
title: Sway replaces cage as the nested compositor
labels: [wayfinder:task]
status: open
assignee:
blocked_by: []
---

## Question

Decided 2026-08-25: **the nested compositor becomes `sway --headless`.** This
ticket is the how and the fallout, not whether.

Three open tickets were each paying cage's bill separately, and none of them is
worth swapping a compositor for on its own:

- [062](062-across-the-vnc-boundary.md) -- the clipboard does not cross, because
  cage never creates a data-control manager. wayvnc has implemented both halves
  all along.
- [062](062-across-the-vnc-boundary.md) again -- no IME can run in the session,
  because there is no `text_input`/`input_method` protocol for one to attach to.
- [041](041-multiple-display-windows.md) -- one screen for everyone, because
  cage is a single-output kiosk and wayvnc serves an output, not a window.

And a fourth, quieter one: cage fullscreens what it starts, which is why
[006](006-no-address-bar-in-handoff.md) had to spend a CDP call taking Chrome
back out of fullscreen so a human gets a toolbar. We pay for kiosk behaviour and
then undo half of it.

## What was measured

Not read off documentation -- read off the binaries, as the wlroots managers each
compositor actually calls and the closure each drags in.

| | closure | data-control | input-method / text-input | `wlr_headless_add_output` | control channel |
|---|---|---|---|---|---|
| cage 0.3.1 | 494 MiB | **none** | **none** | no | none |
| river 0.4.8 | 495 MiB | wlr + ext | v2 / v3 | **absent** | **none shipped** |
| labwc 0.20.1 | 513 MiB | wlr + ext | v2 / v3 | yes, as `VirtualOutputAdd` | none |
| sway 1.12 | 527 MiB | ext | v2 / v3 | yes, as `create_output` | `swaymsg` |

**Cage was never the light one.** It is 33 MiB under sway on a 896 MiB closure --
3.7%, and roughly 10 MB in the bundle. wlroots, Xwayland and mesa dominate all
four; the compositor itself is rounding error. Whatever cage was chosen for, it
was not size.

**Why not river,** which is the genuinely tempting one at a single MiB over cage
and which would close 062 outright: it has no `wlr_headless_add_output` at all,
so 041 has nowhere to go, and 0.4.8 ships exactly one binary. `riverctl` and
`rivertile` are gone; configuration moved into `river-window-management-v1` and
friends, whose XML the package ships for you to implement against. Driving it
means writing and owning a Wayland client, against a compositor that removed its
CLI in a point release.

**Why not labwc:** it can add outputs, but `VirtualOutputAdd` is a keybind
action and there is no IPC client, so asking for one from a shell means binding
a key and synthesising a keypress.

**Why not patch cage** (one call to `wlr_data_control_manager_v1_create`): buys
the clipboard alone, nothing for 041 or the IME, and makes us the maintainers of
a compositor fork.

**Why not our own wlroots compositor:** the map already cites Hyprland 0.56
dropping `hyprctl keyword` -- while exiting 0 -- as the reason to avoid
compositor coupling. Owning one is that risk at maximum against an API that
churns every release.

**Why not X11** (Xvfb + x11vnc), which would make clipboard and in-session drag
nearly free: it costs the real GPU string, and the fingerprint is the product.

## The tension this has to answer honestly

cage was chosen so that *no compositor-specific IPC* was involved, after
backends built on `hyprctl` and `wlrctl` broke. Adopting `swaymsg` looks like
walking straight back into that.

The distinction is which compositor. The breakage was in depending on the
**host's** compositor, whatever the user happened to run, upgraded on their
schedule. Sway here is **ours**: shipped in our closure, pinned in `flake.lock`,
upgraded only when we move the pin, and running a config we generate. That is a
dependency we can test against, and it is the same relationship we already have
with wayvnc's control socket.

That argument only holds while sway stays pinned and internal. If `PASSENGER_WM`
ever grows a "use the host's sway" mode, it stops holding.

## What changes in the code

`Launch.NestedBackend` is the whole of it, plus the session script.

- `Available()` checks `sway`, not `cage`.
- The session script no longer receives Chrome as `cage -- script`. Sway starts
  its child from `exec` in a generated config, so the record-writing trick has
  to be re-derived: `$PPID` is the cage that started the script today, and `$$`
  survives the `exec` to become Chrome's pid. Under sway both change hands.
  Whatever replaces it must still be written **from inside the session**, for
  the reason the current comment gives -- only there are the real
  `WAYLAND_DISPLAY` and pids observable.
- A generated sway config: no bar, no keybindings, `default_border none`, one
  output, and `exec` for Chrome. It is generated per start like
  `cage-session.sh` is, and `SessionSh`'s name stops being true.
- wayvnc must now name its output (`-o HEADLESS-1`), because there can be more
  than one. Today it takes the only one there is.
- Resolution and scale: `swaymsg output HEADLESS-1 resolution/scale` becomes
  available, which the README already points at. `wlr-randr` keeps working --
  sway implements `wlr_output_manager_v1` -- so 002 and 003's client-driven
  resize path is not on the line here, and should be verified unchanged rather
  than redesigned.

## What to check before it closes

- **006's toolbar.** Sway does not fullscreen its children, so the CDP call that
  undoes cage's fullscreen may simply delete. Confirm what a handoff window
  looks like before deleting it, and delete it rather than leaving it inert.
- **The fingerprint is unmoved.** `screen: 1280x720` and the real WebGL adapter
  are the README's measured baseline; a new compositor and a new default output
  are exactly the things that would move them.
- **Sway is not fighting the window.** It tiles by default. One toplevel should
  be indistinguishable from cage's, but a Chrome dialog or a second window is
  where a tiling default shows up.
- **062's clipboard actually crosses** once data-control exists -- that is the
  test that this bought what it was bought for.
- **The closure did not grow more than measured.** 527 MiB was queried against
  the binary cache, not built here.

## What it unblocks

- [062](062-across-the-vnc-boundary.md): clipboard closes as a side effect; the
  IME question becomes "is composing on the host and pasting enough", which it
  probably is.
- [041](041-multiple-display-windows.md): option 2 becomes buildable rather than
  a rewrite. It still needs its own decision about whether anyone wants it --
  this ticket only removes the excuse that it is impossible.
- [060](060-trim-the-closure.md): unrelated to the Python, but the Xwayland
  trim still waits on [061](061-chrome-platform-from-a-dotfile.md) either way.
