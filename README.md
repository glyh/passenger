# passenger

Generic web access through a real, logged-in Chrome that sites can't
distinguish from your daily driver — with a human handoff when a site puts up a
challenge the agent shouldn't (and shouldn't try to) solve.

It is an MCP server and nothing else. Register it with Claude Code for every
project:

    claude mcp add passenger --scope user -- \
      nix run /path/to/passenger

Then ask for a page. The first call starts the Chrome daemon itself; when a
site puts up a login or a captcha, `showBrowser` puts the window in front of
you, you solve it by hand, and the profile keeps the result.

**There is exactly one thing you ever type**, and only when Chrome has wedged
badly enough that the tools cannot reach it:

    Passenger.Mcp stop [--force]

It restarts Chrome at the cost of the warm logged-in session, which is why no
agent can call it and why it refuses while a lane still holds tabs or has the
window on screen. Everything else this used to offer at a terminal -- `script`,
`tabs`, `open`, `close-tabs`, `show`, `hide`, `serve`, `status` -- was a second
copy of a tool, and nobody had ever run any of it. See
`docs/wayfinder/tickets/057-delete-the-cli.md`.

**There is no `fetch`.** There was, with an `article` mode and a `dom` mode,
and ticket 046 retired both: extraction is a judgement about what a page means,
and this tool's whole design says judgement belongs to the caller. `script` is
the only door onto a page — it navigates, drives and hands back what you
return. The recipes for reading one, including the DOM walk that used to be
`dom` mode, live in `skills/using-passenger/`.

## As an MCP server

    Passenger.Mcp        # stdio, and the only thing a client launches

The flake builds a real derivation, so the wrapper already carries sway and
wayvnc on its PATH. That matters more than it looks: without them Chrome
resolves only if they happen to be installed system-wide, and a machine
without them would start Chrome *visible*.

One trap worth knowing if you rewire this: `nix develop --command` forwards
the shellHook to **stdout**, which corrupts any stdio protocol. This flake's
hook prints to stderr for that reason. `nix run` does not run the hook at all,
which is why the registration above is the simpler of the two.

Tools: `openLane`, `setTtl`, `script`, `listTabs`, `closeTabs`,
`closeAllTabs`, `destroyLane`, `showBrowser`, `hideBrowser`,
`browserStatus`.

Four choices worth knowing, all deliberate:

- **An agent opens a lane first.** One Chrome is shared by every agent on the
  machine -- two sessions are two processes, and subagents of one session share
  a single process, so nothing in the transport tells the likely colliders
  apart. A lane owns the tabs opened in it: nobody else can see, list or close
  them. It collects itself after 30 minutes of quiet, closing its tabs. The
  parameter is required rather than defaulted, because a caller isolated by
  accident cannot tell which lane it is in.
- **`script` does not wait for a human.** A tool call that hangs for
  five minutes while someone hunts for a captcha is a bad citizen, so a blocked
  page comes straight back as `type="blocked"` with what is in the way and how
  to clear it. The agent tells the user, the user solves it, the agent calls
  again -- the profile kept the result. `waitSeconds` opts into blocking.
- **The daemon starts on demand.** Nothing has to be started first, by anyone.
- **`showBrowser` exists at all.** The caller is not the human, so summoning one
  is a tool. It waits until they *close the viewer*, which is the only "done"
  signal this side can observe without ruling on the page.

**Operating knowledge for the agent lives in `skills/using-passenger`,**
not in the tool docstrings, which carry the call contract and stop there. That
skill is the one place that says what `blocked` does not catch, how to
recognise a wall this side cannot name, that a read is only the first screen,
how to read a page at all,
and why reading a page beats driving it. It is shipped from this repo and
symlinked into the agent's skill directory, so it sits beside the code it
describes. Six skills in the owner's notes had each hand-copied a paragraph of
it before that existed; ticket 032 has the reasoning, and the rule that came
out of it -- the tool reports what it measured, the skill holds what to look
for.

## Layout

Functional core, imperative shell. The core is pure and testable without a
browser; everything that touches Chrome, the disk, the clock, or a subprocess
lives in the shell.

    core    src/Passenger/Models.cs     every boundary shape, as frozen records
            src/Passenger/Detect.cs     blocked-or-not, given a measurement
            src/Passenger/Errors.cs     ErrorCode + structural errors

    shell   src/Passenger/Service.cs    the one script orchestration, shared by both frontends
            src/Passenger/Browser.cs    Chrome daemon lifecycle, CDP attach
            src/Passenger/Lanes.cs      which lane owns which tab, and when its time is up
            src/Passenger/Targets.cs    Chrome's targets over CDP
            src/Passenger/Probe.cs      measuring a live page into a PageProbe
            src/Passenger/Handoff.cs    summon, notify, poll for a human
            src/Passenger/Launch.cs     hide/show backends
            src/Passenger/Present.cs    putting the hidden browser in front of a human
            src/Passenger/Config.cs     the PASSENGER_* env boundary
            src/Passenger/Script.cs     compiling and running a caller's script with Roslyn
            src/Passenger.Mcp/Program.cs   the entry point: viewer re-exec, `stop`, then the server
            src/Passenger.Mcp/Tools.cs     the ten tools, and the whole surface there is
            src/Passenger.Mcp/Stop.cs      the one verb a human types

    skill   skills/using-passenger/SKILL.md        how an agent operates this: the judgement
            skills/using-passenger/references/     the mechanics, read on demand
            skills/using-passenger/scripts/        markdown.js, unstrip-asides.js, pictures.js

Detection is pure because the shell measures first: `Probe.Run` tests every
candidate selector against the live page and records the hits in a `PageProbe`,
so `Detect.Classify` is a function of that record alone.

    PageProbe(Url: ..., Title: "Just a moment...")
      -> KnownBlocker(Signature: "cloudflare-interstitial")

Blockers are a discriminated union: `Detect.Classify` returns one of a small
sealed set of record types, and an unhandled case in a `switch` expression is a
compiler error rather than a silent fallthrough.

This started as a rewrite of an earlier implementation. `docs/wayfinder/tickets/023-rewriting-into-csharp.md`
has the reasoning and the measurements.

## Design

**Transport and extraction are separate layers, and only one of them is
here.** Per-site scrapers rot because they fuse the two. This side owns
transport: a warm real browser, a tab, a handoff when a human is needed, and a
measurement of what it handed over. Extraction is the caller's, and lives in
`skills/using-passenger/scripts/markdown.js` as a recipe rather than in this
codebase as a mode.

That was not the original design. There were two extractors -- `article`
(trafilatura) and `dom` (a live-DOM walk) -- and the caller chose between them.
Ticket 046 retired both, on the accumulated evidence of this project's own
history: six mechanisms had been deleted for ruling on what a page means (a
yield floor, a word-count tier, a learned signature registry, an `auto` mode, a
wall hint, and a withheld-content reporter that was refused before it was
built), while the two extractors that survived kept failing in the same way --
a root heuristic that returned a promo card as the document, an `article` that
deleted a six-page article's pagination links and swallowed a hidden share
overlay, a `dom` that returned 128,718 characters of comments around a
9,569-character post, and a ticket page that extracted zero characters from a
page holding 2,647.

Extraction is a judgement about what a page means. The agent knows what it
asked for; this side does not.

**What survived the deletion** is one thing: the `blocked` verdict, a fixed
table of vendors' own markup, where a vendor either serves it or does not. The
picture geometry and `charCount` survived it by a year and then went too
(ticket 048) -- not because they were judgement, but because they arrived
whether or not anyone asked. A reply now carries what the script returned, and a
wall if there is one. The wall check itself can be turned off with `checkWall`,
and says `unchecked` when it is, so a page nobody looked at never reads like a
page that came back clean.

**The DOM walk is still this repo's** in the sense that it ships here, and so does
`pictures.js` now -- both in `skills/using-passenger/scripts/`, both recipes the
caller reads off disk and runs in the page. Neither is something this tool decides to
run.

**Known signatures** — Cloudflare, Turnstile, reCAPTCHA, hCaptcha, Arkose,
DataDome, PerimeterX, login walls. Cheap, exact, and the only thing that can
mark a page blocked. The `script` description and the `using-passenger` skill
both list them; the table is fixed at build time and is the same on every
machine.

There was a second tier: anything extracting to under `--min-words` was
treated as blocked, screenshotted, and turned into a proposed signature. It is
gone. A signature match is a positive claim made from things the caller cannot
see — a third-party challenge iframe, a title, a URL. A low word count is not:
its whole evidence is a number already reported back as `char_count`, so the
tool was ruling on something the caller could see for itself, and ruling badly.

It was wrong in three ways at once. The count came from whichever extractor
`--mode` selected, so the same page came back as content or as blocked
depending on a presentation choice. It fired on every legitimately short page —
reading https://example.com, thirty-odd words, used to put the browser on your
screen and block for five minutes. And the rules it guessed were worse than
nothing: a thin page once taught it `^Example Domain`, which then "blocked"
every later read of that site.

So a short page is now simply a short page. You get the content and its size in
characters, and you decide.

**And the table never grows.** Removing the tier that proposed rules left the
store that held them — an on-disk `signatures.json`, with `--approve` and
`--forget` to curate it — and that is gone too. A tool that learns is a second
memory owned by the wrong party: a judgement made once, from one page, filed
where the agent it would affect cannot see it, cannot explain it, and can only
be surprised by it. Anything durable about a *site* belongs in the calling
agent's memory, which is written deliberately, attributed, re-read in context,
and cheap to delete when it turns out to be wrong. The builtins are not an
exception — they are how challenge vendors identify themselves, true
regardless of who is calling.

## Hiding the window

Chrome runs inside its own nested **sway** compositor, started headless with a
config this tool writes on every launch — no bar, no keybindings, no
decorations. Your host compositor never sees a window, so this works identically
on any Wayland compositor, or over SSH — and survives switching between them.
`show` attaches a VNC viewer to that session; a challenge handoff does it
automatically and re-hides afterwards.

**It was cage until ticket 063**, and cage is a kiosk: one output, one
fullscreened window, nothing to ask. Three things were paying for that. wayvnc
implements the clipboard in both directions and cage offered no data-control
protocol for it to talk to, so nothing pasted across the glass. There was no
`text-input` or `input-method`, so no IME could run in the session at all —
which on a CJK machine means the browser you are handed cannot be typed into.
And one output forever means two humans can never be handed two screens
(`docs/wayfinder/tickets/041-multiple-display-windows.md`). sway costs 33 MiB
more in a 896 MiB closure, answers on a socket, and offers all three.

The fullscreen is gone with cage: sway does not fullscreen what it starts, so
the browser is windowed from the start. Chrome is still put back into a window
before every handoff, because a *page* can call the Fullscreen API and a human
can press F11 — and a fullscreen Chrome hides its own tab strip and toolbar, so
whoever is solving the captcha would have no address bar, no back button and no
tabs.

Hardware GL survives the move (the session uses `/dev/dri/renderD128`), so the
fingerprint is unchanged. The one delta is `screen: 1280x720`, which is now set
in the generated config rather than inherited from a compositor default —
change it there, or at runtime with
`swaymsg output HEADLESS-1 resolution 1920x1080`.

Selectable via `PASSENGER_WM`:

### Presenters (`PASSENGER_PRESENTER`)

| value   | how you take over | notes |
|---------|-------------------|-------|
| `local` | a chromeless window of your own browser | default; app mode, so no tab strip or address bar |
| `web`   | the URL, to open wherever you are | for containers/servers with no display of their own |
| `none`  | nothing           | honest about having no way to show it |

**What crosses the glass:** keys, pointer, and clipboard text in both
directions -- the clipboard read from the host each time the viewer window takes
focus, since noVNC swallows the keystroke that would otherwise be a paste. Files
do not: RFB has no file transfer, so a file dropped on the viewer is refused
outright rather than left for the host browser to open in a window of its own.
A file gets in through the page's own file input, whose chooser opens on the
host desktop and can reach any path. CJK is typed rather than pasted, because
the session runs the host's own IME inside itself -- see below.

Both are the same page (`passenger/web/viewer.html`), a full-bleed noVNC
screen. There is no native VNC client involved: noVNC asks for the framebuffer size its
window needs and keeps asking as the window changes, which is something no
native client here did: the lightweight ones stretch whatever they are sent
and freeze that aspect at connect time, and the one that does resize costs
1.2 GiB against noVNC's 1.8 MB.

### Launch (`PASSENGER_WM`)

| value    | mechanism               | notes |
|----------|-------------------------|-------|
| `nested` | sway + wayvnc (default) | the only real mechanism; portable everywhere |
| `none`   | no-op                   | fallback when sway/wayvnc are missing — the window stays visible |

Compositor-specific backends (hyprctl special workspaces, `wlrctl` minimize)
were tried and removed. They break: Hyprland 0.56 dropped `hyprctl keyword` and
moved dispatch to Lua, and did it while still exiting 0. Running Chrome in its
own compositor sidesteps that whole class of breakage.

## Typing in the nested browser

The session borrows **the fcitx5 you are already running** -- not a second
instance. fcitx5 exposes `OpenWaylandConnection` on its D-Bus interface for
exactly this, one process serving several compositors, so the session starts by
asking yours to attach to the nested display as well:

    dbus-send --session --dest=org.fcitx.Fcitx5 --type=method_call /controller \
      org.fcitx.Fcitx.Controller1.OpenWaylandConnection string:"$WAYLAND_DISPLAY"

Which means your real config, your real learned dictionary, and whatever you
changed this morning -- live, not copied. It also means nothing to tear down:
fcitx5 drops the connection when the display goes away.

Sway offers the `text-input` and `input-method` protocols cage never did, and
Chrome already speaks them, so that one call is the entire mechanism.

An earlier version started a private fcitx5 on a private bus against a *copy* of
`~/.config/fcitx5`. It was replaced within the hour, for the reason its owner
asked out loud: why run a second one? The copy also turned out to be a symlink
back to the original, so the isolation it claimed was never real.

**It is off by default, because it crashes Chrome.** `PASSENGER_IME=fcitx5`
turns it on; measured on fresh profiles one variable apart, the browser runs a
clean minute without it and segfaults within a second with it. A separate fcitx5
attached by hand crashes it the same way, so the fault is an input method being
present rather than this reuse. Ticket 067 has the measurements and the places
to look. Until then CJK goes in by pasting, which the viewer's clipboard
supports both ways.

## Environment

    PASSENGER_STATE         state dir (default ~/.local/share/passenger)
    PASSENGER_PORT          CDP port (default 9222)
    PASSENGER_CHROME        chrome binary (default google-chrome-stable)
    PASSENGER_HANDOFF_TIMEOUT  seconds to wait for you (default 300)
    PASSENGER_IME           `none` (default; see ticket 067) or `fcitx5`, which
                            asks the running one to serve the session too
    PASSENGER_WM            window backend
    PASSENGER_VNC_HOST/PORT default 127.0.0.1:5900 (websocket)
    PASSENGER_NOVNC_PORT    viewer page (default 6080)
    PASSENGER_NOVNC         noVNC install dir (the flake sets this)
    PASSENGER_VIEWER        browser for the viewer window (default: the Chrome above)
    PASSENGER_VNC_SCALE     nested output scale (default: the host screen's)

## Install

    nix develop            # dev shell: sway, wayvnc, noVNC, the dotnet SDK
    nix run .              # run the MCP server (there is no other app)

The flake pins everything except the browser and the .NET SDK itself --
`deps.json` locks every NuGet package by hash (regenerate it with
`nix build .#default.passthru.fetch-deps`), and `nix build` needs no network
once that lockfile is current. The one NuGet-side patch: Patchright bundles its
own Node to drive Playwright's wire protocol, built against
`/lib64/ld-linux-x86-64.so.2`, which does not exist in the store -- the package
substitutes nixpkgs' own `node` for it post-build instead. Chrome deliberately
comes from the host (`PASSENGER_CHROME`, default
`google-chrome-stable`): pinning it would freeze its version, and the version
string is one of the most visible fingerprint fields there is -- a browser
months behind what real users run is a tell in itself, and stops getting
security updates.

That is a decision about *which browser*, and it was never one about the
browser's configuration. The nested session passes `--ozone-platform=wayland`
itself -- it serves Wayland and nothing else, and used to be left to work that
out -- and runs Chrome against a symlink mirror of `$XDG_CONFIG_HOME` with
`chrome-flags.conf` left out, since the distribution's launcher is a shell
wrapper that splices that file into argv. A mirror rather than an empty
directory: fontconfig's config lives there too, and inheriting the host's fonts
is the argument below against containers.

Without nix, install the equivalents yourself: `sway wayvnc` plus a copy of
noVNC (`PASSENGER_NOVNC`, or one of the usual `/usr/share/novnc` paths).

### Why not Docker

This tool's whole value is *inheriting* the host: its fonts (819 here, 115 of
them CJK), its GPU, its residential IP, its timezone. A container isolates
exactly those, so a Dockerfile would spend its length painstakingly rebuilding
them -- baking in a font set, passing through `/dev/dri`, pinning TZ and locale
-- and would still only approximate the real thing. Measured under nix, the
fingerprint is untouched:

    webgl : ANGLE (Intel, Mesa Intel(R) Graphics (LNL), OpenGL ES 3.2)
    tz    : Asia/Shanghai

Nix isolates the dependency graph, which was the actual problem, and leaves the
machine identity alone.

Docker is still the right tool for a *headless server* deployment, where there
is no host identity worth inheriting. `Present.cs` (web/noVNC) and `Notify.cs`
(webhook) exist so that case works.

Requires without nix: `sway wayvnc` (swaymsg ships with sway) and noVNC's
static files. wayvnc serves the
websocket itself, so nothing else has to run; if the page cannot be served the
tool prints the address so you can point your own noVNC at it, from another
machine or a phone.
