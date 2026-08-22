# agent-browser

Generic web-context fetching through a real, logged-in Chrome that sites can't
distinguish from your daily driver — with a human handoff when a site puts up a
challenge the agent shouldn't (and shouldn't try to) solve.

    agent-browser serve                  # start the hidden Chrome daemon
    agent-browser fetch <url>            # → markdown on stdout
    agent-browser fetch <url> --json     # → {url,title,words,markdown}
    agent-browser open <url>             # park a URL in a tab, no window
    agent-browser open <url> --show      # ...and show it, to log in by hand
    agent-browser fetch <url> --close-tabs   # ...and tidy up after
    agent-browser close-tabs             # clear tabs orphaned by earlier runs
    agent-browser show | hide | stop | status
    agent-browser signatures [--approve NAME | --forget NAME]

## As an MCP server

    agent-browser-mcp        # stdio

Register it with Claude Code for every project:

    claude mcp add agent-browser --scope user -- \
      nix develop /path/to/agent-browser --command \
      uv run --project /path/to/agent-browser agent-browser-mcp

`nix develop` rather than a bare `uv run`: uv heals the Python side on its own
(it creates and syncs .venv from uv.lock, fetching the interpreter if needed),
but it knows nothing about cage and wayvnc. Without the flake shell those
resolve only if they also happen to be installed system-wide, and a machine
without them would start Chrome *visible*.

Two traps that cost real debugging, both worth knowing if you rewire this:

- `nix develop --command` forwards the shellHook to **stdout**, which corrupts
  any stdio protocol. This flake's hook prints to stderr for that reason.
- `direnv exec <dir> uv run ...` is the fast alternative -- 0.16s against 3.0s,
  thanks to nix-direnv's cache, and its stdout is clean. It is not the default
  only because editing .envrc revokes direnv's approval until you re-allow it,
  which would break the server at the worst moment.

Tools: `fetch`, `show_browser`, `hide_browser`, `browser_status`,
`close_tabs`, `list_blockers`.

Two things differ from the CLI, both deliberate:

- **`fetch` does not wait for a human by default.** A tool call that hangs for
  five minutes while someone hunts for a captcha is a bad citizen, so a blocked
  page comes straight back as `type="blocked"` with what is in the way and how
  to clear it. The agent tells the user, the user solves it, the agent calls
  again -- the profile kept the result. `wait_seconds` opts into blocking.
- **The daemon starts on demand.** A human runs `serve` first; an agent should
  not have to know that.

## Layout

Functional core, imperative shell. The core is pure and testable without a
browser; everything that touches Chrome, the disk, the clock, or a subprocess
lives in the shell.

    core    models.py    every boundary shape, as frozen pydantic models
            detect.py    blocked-or-not, given a measurement
            extract.py   article/dom text handling + the `auto` decision
            errors.py    ErrorCode + structural errors

    shell   service.py   the one fetch orchestration, shared by both frontends
            browser.py   Chrome daemon lifecycle, CDP attach
            probe.py     measuring a live page into a PageProbe
            handoff.py   summon, notify, poll for a human
            window.py    hide/show backends (Protocol)
            registry.py  signatures.json
            config.py    the AGENT_BROWSER_* env boundary
            cli.py       cyclopts; the only place a failure becomes terminal output
            mcp_server.py  the MCP frontend over the same service layer

Detection is pure because the shell measures first: `probe.probe()` tests every
candidate selector against the live page and records the hits in a `PageProbe`,
so `detect.classify()` is a function of that record alone.

    PageProbe(url=..., title='Just a moment...', word_count=3)
      -> KnownBlocker(signature=cloudflare-interstitial)

Blockers are a discriminated union closed with `assert_never`, so adding a
variant without handling it is a type error rather than a silent fallthrough.
`mypy --strict` passes; run it with `uv run mypy ab`.

## Design

**Transport and extraction are separate layers.** Per-site scrapers rot because
they fuse the two. Here anything fetchable is `navigate + extract`, and the
extraction half is the part that never goes stale.

### Extraction modes (`--extract`)

| mode | what it does |
|---|---|
| `auto` (default) | runs the article extractor, falls back to DOM text only if it recovered under 35% of the page's visible words |
| `article` | trafilatura boilerplate removal → markdown |
| `dom` | visible text off the live DOM, minus nav/header/footer/aria-hidden |

**`dom` is an escape hatch that has not yet proved necessary.** It was added on
the assumption that trafilatura returns nav chrome for JS apps. Measured, that
turned out to be false — with `favor_recall=True` it wins on every page tried,
including app-shaped ones:

| page | article | dom |
|---|---|---|
| Wikipedia article | 4145 w | — |
| Google Calendar agenda | 494 w | 347 w |
| Gmail inbox | 4878 w | 4144 w |
| Google Maps | 107 w | 30 w |

Both modes recovered identical event counts on Calendar (16 / 4). So `auto` has
never actually fired its fallback. Keep `dom` for the page that eventually
needs it; don't assume an app-shaped page is one of them without measuring.
(Google Maps is a reminder that some pages lose to *both* — the content is in a
canvas, and no text extractor will help.)

**Nothing is spoofed.** The profile is a real Chrome on your real IP, so there
is no fake fingerprint to catch — only the automation protocol needed patching,
which is what patchright does (notably avoiding the `Runtime.enable` CDP leak).
Verified: `navigator.webdriver=false`, no `Headless` in the UA, 5 plugins, no
`cdc_` globals, WebGL reporting the genuine adapter rather than SwiftShader.

**The window appears only when a human is needed.** Navigating and displaying
are separate commands: `open` parks a URL silently, `show` puts the browser on
screen. The one place presentation happens on its own is a challenge handoff --
which is the definition of actually necessary -- and it re-hides afterwards if
it was hidden when it started.

**Challenges are handed to you, never auto-solved.** Solver services get
profiles burned and make you *more* detectable. You solve it once; the
persistent profile keeps the clearance cookie. Note `cf_clearance` is bound to
IP + User-Agent, which is why this runs locally rather than on a VPS.

### Two-tier detection

1. **Known signatures** — Cloudflare, Turnstile, reCAPTCHA, hCaptcha, Arkose,
   DataDome, PerimeterX, login walls. Cheap and exact.
2. **"Did I actually get content?"** — anything extracting to under
   `--min-words` (default 80) is treated as blocked. This is what catches
   challenge types that didn't exist when this was written: it screenshots the
   page, dumps iframe hosts and visible text to `reports/`, and proposes a new
   signature.

Proposed signatures are marked `pending_review` and **do not match** until you
approve them. That is deliberate: a rule guessed from one page will otherwise
false-positive forever. (Observed during development — a thin page taught it
`^Example Domain`, which then "blocked" every later fetch of that site.)

## Hiding the window

Chrome runs inside its own nested **cage** compositor. Your host compositor
never sees a window, so this works identically on any Wayland compositor, or
over SSH — and survives switching between them. `show` attaches a VNC
viewer to that session; a challenge handoff does it automatically and re-hides
afterwards.

cage is a kiosk compositor: it fullscreens what it starts, and a fullscreen
Chrome hides its own tab strip and toolbar — so the browser you were handed to
solve a captcha had no address bar, no back button and no tabs. It is taken
back out of fullscreen at start, and again before every handoff, so what you
take over is an ordinary browser window.

Hardware GL survives the move (the session uses `/dev/dri/renderD128`), so the
fingerprint is unchanged. The one delta is `screen: 1280x720`, cage's default
headless output — plausible but fixed. Swap cage for `sway --headless` if you
need to control it (`swaymsg output HEADLESS-1 resolution 1920x1080`).

Selectable via `AGENT_BROWSER_WM`:

### Presenters (`AGENT_BROWSER_PRESENTER`)

| value   | how you take over | notes |
|---------|-------------------|-------|
| `local` | a chromeless window of your own browser | default; app mode, so no tab strip or address bar |
| `web`   | the URL, to open wherever you are | for containers/servers with no display of their own |
| `none`  | nothing           | honest about having no way to show it |

Both are the same page (`ab/web/viewer.html`), a full-bleed noVNC screen. There
is no native VNC client involved: noVNC asks for the framebuffer size its
window needs and keeps asking as the window changes, which is something no
native client here did: the lightweight ones stretch whatever they are sent
and freeze that aspect at connect time, and the one that does resize costs
1.2 GiB against noVNC's 1.8 MB.

### Launch (`AGENT_BROWSER_WM`)

| value    | mechanism               | notes |
|----------|-------------------------|-------|
| `nested` | cage + wayvnc (default) | the only real mechanism; portable everywhere |
| `none`   | no-op                   | fallback when cage/wayvnc are missing — the window stays visible |

Compositor-specific backends (hyprctl special workspaces, `wlrctl` minimize)
were tried and removed. They break: Hyprland 0.56 dropped `hyprctl keyword` and
moved dispatch to Lua, and did it while still exiting 0. Running Chrome in its
own compositor sidesteps that whole class of breakage.

## Environment

    AGENT_BROWSER_STATE     state dir (default ~/.local/share/agent-browser)
    AGENT_BROWSER_PORT      CDP port (default 9222)
    AGENT_BROWSER_CHROME    chrome binary (default google-chrome-stable)
    AGENT_BROWSER_MIN_WORDS tier-2 threshold (default 80)
    AGENT_BROWSER_HANDOFF_TIMEOUT  seconds to wait for you (default 300)
    AGENT_BROWSER_WM        window backend
    AGENT_BROWSER_VNC_HOST/PORT    default 127.0.0.1:5900 (websocket)
    AGENT_BROWSER_NOVNC_PORT       viewer page (default 6080)
    AGENT_BROWSER_NOVNC     noVNC install dir (the flake sets this)
    AGENT_BROWSER_VIEWER    browser for the viewer window (default: the Chrome above)
    AGENT_BROWSER_VNC_SCALE nested output scale (default: the host screen's)

## Install

    nix develop            # dev shell: cage, wayvnc, noVNC, python, uv
    nix run .              # run the CLI directly

The flake pins everything except the browser. Chrome deliberately comes from
the host (`AGENT_BROWSER_CHROME`, default `google-chrome-stable`): pinning it
would freeze its version, and the version string is one of the most visible
fingerprint fields there is -- a browser months behind what real users run is a
tell in itself, and stops getting security updates.

Without nix, install the equivalents yourself: `cage wayvnc` plus a copy of
noVNC (`AGENT_BROWSER_NOVNC`, or one of the usual `/usr/share/novnc` paths).

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
is no host identity worth inheriting. `present.py` (web/noVNC) and `notify.py`
(webhook) exist so that case works.

Requires without nix: `cage wayvnc` and noVNC's static files. wayvnc serves the
websocket itself, so nothing else has to run; if the page cannot be served the
tool prints the address so you can point your own noVNC at it, from another
machine or a phone.
