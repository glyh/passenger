---
id: 062
title: Clipboard, IME and drag-and-drop do not cross the VNC boundary
labels: [wayfinder:task]
status: closed
assignee:
blocked_by: []
---

## Question

The handoff hands a human a browser they cannot type Chinese into, paste into,
or drag a file onto. Everything this tool does rests on that handoff working
(the map's own framing: the session staying warm and real, and the handoff
actually working when it is needed), so three things a person reaches for
within seconds of taking over are missing.

They have three different causes. Measured on the live session rather than
guessed, by asking cage what it advertises:

    XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 wayland-info

    wl_compositor  wl_data_device_manager  wl_seat  wl_shm  wl_output
    xdg_wm_base  xwayland_shell_v1  zwlr_screencopy_manager_v1
    zwlr_virtual_pointer_manager_v1  zwp_virtual_keyboard_manager_v1
    zwp_primary_selection_device_manager_v1  ... (25 in total)

### 1. Clipboard: wayvnc can do it; cage does not offer the protocol

This one is not a design problem and not an RFB limit. wayvnc already
implements clipboard in both directions -- its binary carries
`Clipboard read failed`, `Clipboard write incomplete due to client
disconnection`, and both `data_control_device_listener_wlr` and
`..._ext`, so it speaks the wlr and ext variants of the data-control
protocol.

The list above has neither. `strings` on the cage binary finds no
`data_control` at all: wlroots implements the protocol, cage never creates the
manager. So there is a clipboard on each side of the glass and no protocol
between them, and the fix is not in this repo -- it is which compositor holds
Chrome.

### 2. IME: nothing in the nested session can compose

`zwp_text_input_manager_v3` and `zwp_input_method_v2` are both absent, so the
host's fcitx or ibus has nothing to attach to and no IME can run inside the
cage. wayvnc is not a way around it either: it drives
`zwp_virtual_keyboard_manager_v1` and resolves each RFB keysym against a fixed
xkb keymap (`-k <layout>`, `xkb_keymap_key_get_syms_by_level`). A CJK codepoint
is not a keysym in any layout, so there is no keystroke to send.

That leaves composing on the *host* -- where the viewer page runs in the host's
own Chrome and the host IME works normally -- and moving the result across as
text. Which is the clipboard. **So 2 is mostly 1**, and the order matters:
fixing the clipboard makes CJK entry possible by paste, without any IME inside
the session at all. A real in-session IME is a separate and much larger
question, and this ticket should not answer it.

### 3. Drag-and-drop: two different asks, one of them impossible

`wl_data_device_manager` *is* advertised, so dragging inside the session --
within a page, between two Chrome windows -- is a pointer-event problem, not a
protocol one. If that is what is broken, suspect the virtual pointer: ticket
004 measured that CDP `click` teleports the cursor, and a synthesised pointer
that jumps rather than moves is exactly what an HTML5 drag does not survive.
Worth reproducing before assuming.

Dragging *across* the boundary -- a file from the host's file manager onto the
nested page -- has no channel in RFB and will not get one. The honest remedy is
the one the skill already documents for pictures: the server runs on the same
filesystem, so a path is passed and read, and nothing is dragged. If a human
needs to upload a file during a handoff, the answer is the file chooser inside
the session, which is a real Chrome dialog on a real filesystem.

## What to decide

1. **Whether this is one ticket or the compositor ticket in disguise.** 1 is
   fixed by a compositor that advertises data-control; 041 wants a compositor
   that can create several outputs; both point away from cage. If the
   compositor is replaced, 1 closes as a side effect and only 3 remains here.
2. **Whether 3 is even broken.** It is asserted, not reproduced. Establish
   which of the two asks was meant, and for the in-session one, whether a drag
   works when the pointer is moved by wayvnc rather than by CDP.
3. **What the handoff should tell the human.** Whatever is not fixed should be
   said out loud when the browser is put in front of someone -- a person who
   does not know the clipboard is dead will spend a minute finding out.

## The compositor question is settled

*2026-08-25.* [063](063-sway-instead-of-cage.md) takes sway, which creates an
`ext_data_control_manager_v1`. Cause 1 closes with it, and cause 2 reduces to
composing on the host and pasting. Cause 3 -- whether an in-session drag
survives a synthesised pointer -- is untouched by the swap and is what remains
of this ticket.

## Related

[One screen for everyone, or one window each](041-multiple-display-windows.md)
is the other ticket whose answer is "not cage". They should be decided
together, since both are paying for the same choice and neither is worth
replacing a compositor for on its own.

## Answer

*Closed 2026-08-25.* All three crossed, and they needed fixes at two different
layers -- which is why the ticket was worth keeping whole.

**Clipboard: works, both directions, verified by a human.** It took the
compositor swap ([063](063-sway-instead-of-cage.md)) for a data-control protocol
to exist at all, and then a bridge in `viewer.html`, which had been attaching a
framebuffer and wiring nothing else. The direction that is not obvious: host to
session cannot be a `paste` listener, because noVNC calls `preventDefault` on
every key it forwards, so Ctrl+V never becomes a paste event on the host page.
The host clipboard is read when the viewer window *gains focus* instead. That is
a sequence a human has to be told -- copy, click the window, paste -- and it is
now in `references/tabs-and-lanes.md`.

**IME: reduced to the clipboard, and left there.** Nothing in the session
composes and no IME can attach, so a human cannot *type* Chinese into the
browser they are handed. They can paste it, which is what the clipboard fix
bought and what the skill now says. An in-session IME was left unbuilt here and
built the same day: [066](066-an-ime-in-the-session.md) runs the host's own
fcitx5 inside the session, so CJK is typed rather than pasted. The clipboard
route stays as the answer for a machine with no IME to lend.

**Drag: split in two, and both halves are settled.** Inside the page -- a
slider, a reorder, an HTML5 drop target -- it works, tested by hand; wayvnc
feeds real pointer motion, so the concern inherited from ticket 004's teleporting
CDP cursor did not apply. Across the boundary it does not work and will not: RFB
carries no file transfer. What was actually broken there was that a dropped file
made the *host* browser navigate to it, which looked like something happening;
the viewer now refuses `dragover`/`drop` outright.

The capability behind the drag was never missing. A file input in the nested
page opens a chooser on the host desktop, reaches any path, and delivers the
file to the nested renderer -- measured end to end with a 133-byte `wifi.md`.
So the thing to tell a human is "click the upload button", never "drag it in",
and that is documented rather than left to be rediscovered.
