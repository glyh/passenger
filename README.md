# agent-browser

Generic web-context fetching through a real, logged-in Chrome that sites can't
distinguish from your daily driver — with a human handoff when a site puts up a
challenge the agent shouldn't (and shouldn't try to) solve.

    agent-browser serve                  # start the hidden Chrome daemon
    agent-browser fetch <url>            # → markdown on stdout
    agent-browser fetch <url> --json     # → {url,title,words,markdown}
    agent-browser open <url>             # show the window, log in by hand
    agent-browser show | hide | stop | status
    agent-browser signatures [--approve NAME | --forget NAME]

## Layout

Functional core, imperative shell. The core is pure and testable without a
browser; everything that touches Chrome, the disk, the clock, or a subprocess
lives in the shell.

    core    models.py    every boundary shape, as frozen pydantic models
            detect.py    blocked-or-not, given a measurement
            extract.py   article/dom text handling + the `auto` decision
            errors.py    ErrorCode + structural errors

    shell   browser.py   Chrome daemon lifecycle, CDP attach
            probe.py     measuring a live page into a PageProbe
            handoff.py   summon, notify, poll for a human
            window.py    hide/show backends (Protocol)
            registry.py  signatures.json
            config.py    the AGENT_BROWSER_* env boundary
            cli.py       cyclopts; the only place a failure becomes terminal output

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

Hardware GL survives the move (the session uses `/dev/dri/renderD128`), so the
fingerprint is unchanged. The one delta is `screen: 1280x720`, cage's default
headless output — plausible but fixed. Swap cage for `sway --headless` if you
need to control it (`swaymsg output HEADLESS-1 resolution 1920x1080`).

Selectable via `AGENT_BROWSER_WM`:

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
    AGENT_BROWSER_VNC_HOST/PORT    default 127.0.0.1:5900

Requires: `cage wayvnc gtk-vnc` (or any VNC client — if none is found the tool
prints the address so you can connect from another machine or a phone).
