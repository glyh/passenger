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

## Design

**Transport and extraction are separate layers.** Per-site scrapers rot because
they fuse the two. Here anything fetchable is `navigate + extract`, and the
extraction half (trafilatura → markdown) is the part that never goes stale.

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
never sees a window, so this works identically on Hyprland, sway, niri, GNOME,
KDE, or over SSH — and survives switching between them. `show` attaches a VNC
viewer to that session; a challenge handoff does it automatically and re-hides
afterwards.

Hardware GL survives the move (the session uses `/dev/dri/renderD128`), so the
fingerprint is unchanged. The one delta is `screen: 1280x720`, cage's default
headless output — plausible but fixed. Swap cage for `sway --headless` if you
need to control it (`swaymsg output HEADLESS-1 resolution 1920x1080`).

Backends are pluggable via `AGENT_BROWSER_WM`:

| value      | mechanism                        | notes |
|------------|----------------------------------|-------|
| `nested`   | cage + wayvnc (default)          | portable everywhere |
| `wlrctl`   | wlr-foreign-toplevel minimize    | wlroots only; minimize is advisory |
| `hyprland` | special workspace                | **broken on Hyprland ≥0.56** — `hyprctl keyword` was removed and dispatch became a Lua API (`hl.dsp.*`). Worse, `hyprctl keyword` exits 0 while printing an error, so it fails silently. Legacy only. |
| `none`     | no-op                            | window stays visible |

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
