---
id: 060
title: The bundle carries a Python nothing runs
labels: [wayfinder:task]
status: open
assignee:
blocked_by: []
---

## Question

`nix bundle --bundler github:NixOS/bundlers#toArx .#packages.x86_64-linux.default`
produces one 302 MB executable that speaks MCP on a machine with no nix — the
whole runtime side travels, Chrome deliberately does not, and the compositor
still starts where there is no GPU (measured: vulkan fails, wlroots falls back
to the pixman renderer, cage runs its child, exit 0). That is the artifact this
ticket is about; it is not what is in question.

The closure behind it is 896 MiB across 258 paths, and its largest single entry
is a Python interpreter:

     135.4 MiB  python3-3.14.7
      85.7 MiB  nodejs-slim-24.19.0   (+ npm 12.1 MiB, + corepack)
      78.3 MiB  dotnet-runtime-10.0.10
      41.6 MiB  gtk+3-3.24.52
      39.5 MiB  icu4c-78.3
      36.1 MiB  passenger-0.1.0       <- the build itself
      33.8 MiB  ffmpeg-9.0-lib
      33.4 MiB  glibc-2.42-67

**Nothing in this project has run Python since ticket 023.** It arrives through
a shebang, on a script for analysing mouse buttons:

    Passenger.Mcp -> cage -> wlroots -> libinput-1.31.3-dev
      -> libinput-1.31.3-bin
      -> libexec/libinput/libinput-analyze-buttons   #!/nix/store/...-python3-3.14.7-env

`wlroots` propagates `libinput-dev`, `libinput-dev` propagates `libinput-bin`,
and one interpreter line in a tool this codebase will never invoke makes CPython
a runtime dependency of an MCP server. `Launch.cs` starts cage with
`WLR_LIBINPUT_NO_DEVICES=1`, so there are not even input devices for it to
analyse.

The question is what removes it without lying to the closure scanner:
`removeReferencesTo` on the wrapper, a `libinput` override that drops the `bin`
output, or overriding `wlroots`'s propagation. Whichever it is, it has to be
checked against a real handoff -- cage starting, wayvnc serving, a viewer
attaching -- and not only against `nix build` succeeding.

## Two neighbours, measured but not settled here

**Node is load-bearing; `npm` and `corepack` are not.** Playwright's wire
protocol is driven by a Node process, and `postFixup` substitutes nixpkgs' node
for Patchright's bundled one. It reaches for `pkgs.nodejs`, which carries npm
and corepack; `pkgs.nodejs-slim` is the same interpreter without them. The
interpreter itself, 85.7 MiB, is not negotiable.

**gtk+3 is Xwayland's, and Xwayland may be load-bearing:**

    Passenger.Mcp -> cage -> xwayland-24.1.13 -> libdecor-0.2.5 -> gtk+3

Nothing here links gtk. It arrives because libdecor draws client-side window
decorations, which Xwayland wants. Building cage and wlroots without Xwayland
would drop both -- *if* Chrome is a Wayland client inside the cage, and it is
not obviously one: nothing in `Launch.cs` or `Browser.cs` passes
`--ozone-platform=wayland` or `--ozone-platform-hint=auto`, so Chrome may well
be taking the X11 path through Xwayland today, which would make this a
behaviour change rather than a trim. Answer that first, by looking for an
Xwayland process in a live session. If Chrome does have to be moved onto
Wayland to drop it, that is a fingerprint-adjacent change and belongs in its
own ticket.

## Why this is worth doing at all

Not the megabytes on their own. The tool inherits the host on purpose -- its
fonts, its GPU, its IP -- and a closure that also inherits a Python for a mouse
utility is the same failure in the other direction: things arriving because
nothing stopped them, rather than because someone asked. The bundle is the
first artifact where that cost is visible to whoever downloads it.
