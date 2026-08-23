# agent-browser

Generic web-context fetching through a real, logged-in Chrome that sites can't
distinguish from your daily driver — with a human handoff when a site puts up a
challenge the agent shouldn't (and shouldn't try to) solve.

    agent-browser serve                  # start the hidden Chrome daemon
    agent-browser fetch <url>            # → markdown on stdout
    agent-browser fetch <url> --json     # → {url,title,char_count,markdown}
    agent-browser open <url>             # park a URL in a tab, no window
    agent-browser open <url> --show      # ...and show it, to log in by hand
    agent-browser fetch <url> --close-tabs   # ...and tidy up after
    agent-browser close-tabs             # clear tabs orphaned by earlier runs
    agent-browser show | hide | stop | status

## As an MCP server

    agent-browser-mcp        # stdio

Register it with Claude Code for every project:

    claude mcp add agent-browser --scope user -- \
      nix run /path/to/agent-browser#mcp

The flake builds a real derivation, so the wrapper already carries cage and
wayvnc on its PATH. That matters more than it looks: without them Chrome
resolves only if they happen to be installed system-wide, and a machine
without them would start Chrome *visible*.

One trap worth knowing if you rewire this: `nix develop --command` forwards
the shellHook to **stdout**, which corrupts any stdio protocol. This flake's
hook prints to stderr for that reason. `nix run` does not run the hook at all,
which is why the registration above is the simpler of the two.

Tools: `fetch`, `script`, `list_tabs`, `show_browser`, `hide_browser`,
`browser_status`, `close_tabs`.

Two things differ from the CLI, both deliberate:

- **`fetch` does not wait for a human by default.** A tool call that hangs for
  five minutes while someone hunts for a captcha is a bad citizen, so a blocked
  page comes straight back as `type="blocked"` with what is in the way and how
  to clear it. The agent tells the user, the user solves it, the agent calls
  again -- the profile kept the result. `wait_seconds` opts into blocking.
- **The daemon starts on demand.** A human runs `serve` first; an agent should
  not have to know that.
- **`show_browser` exists at all.** The CLI has nothing like it on purpose:
  there, the caller is already the human. Over MCP the caller is not, so
  summoning one is a tool. It waits until they *close the viewer*, which is
  the only "done" signal this side can observe without ruling on the page.

**Operating knowledge for the agent lives in `skills/using-agent-browser`,**
not in the tool docstrings, which carry the call contract and stop there. That
skill is the one place that says what `blocked` does not catch, how to
recognise a wall this side cannot name, that a fetch is only the first screen,
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

    core    models.py    every boundary shape, as frozen pydantic models
            detect.py    blocked-or-not, given a measurement
            extract.py   article/dom text handling
            errors.py    ErrorCode + structural errors

    shell   service.py   the one fetch orchestration, shared by both frontends
            browser.py   Chrome daemon lifecycle, CDP attach
            probe.py     measuring a live page into a PageProbe
            handoff.py   summon, notify, poll for a human
            window.py    hide/show backends (Protocol)
            config.py    the AGENT_BROWSER_* env boundary
            cli.py       cyclopts; the only place a failure becomes terminal output
            mcp_server.py  the MCP frontend over the same service layer

    skill   skills/using-agent-browser/SKILL.md   how an agent operates this

Detection is pure because the shell measures first: `probe.probe()` tests every
candidate selector against the live page and records the hits in a `PageProbe`,
so `detect.classify()` is a function of that record alone.

    PageProbe(url=..., title='Just a moment...')
      -> KnownBlocker(signature=cloudflare-interstitial)

Blockers are a discriminated union closed with `assert_never`, so adding a
variant without handling it is a type error rather than a silent fallthrough.
`mypy --strict` passes; run it with `mypy ab` in `nix develop`.

## Design

**Transport and extraction are separate layers.** Per-site scrapers rot because
they fuse the two. Here anything fetchable is `navigate + extract`, and the
extraction half is the part that never goes stale.

### Extraction modes (`--extract`)

| mode | what it does | right for |
|---|---|---|
| `article` | trafilatura boilerplate removal → markdown | a document: an article, a post, a docs page |
| `dom` | visible text off the live DOM, minus nav/header/footer/aria-hidden | a listing, feed, profile or search result |

**There is no default, and no `auto`.** `auto` ran both extractors and picked
by comparing their word counts; which one is right depends on the page's
*type*, and that is not in the two blobs of text a comparison is handed, so
every signal it computed was a proxy for something it could not measure. It is
gone, and `mode` is required at both doors rather than defaulted, because the
caller knows what it pointed at and a tool that guesses silently is worse than
one that asks. The failure it used to hide is worth stating: `article` on a
listing returns the site footer and none of the cards.

Both modes render links inline as `[label](url)`, resolved against the page's
own URL and otherwise passed through untouched — query strings included, since
on some sites the token in the query string is what makes the URL work at all.
`dom` used to return text only, which cost a listing the only part of it that
was navigable; it also read `innerText` off a *detached clone*, where innerText
degrades to `textContent`, so every block boundary was lost and whatever line
structure survived was the source HTML's own whitespace. A xiaohongshu search
page came back as one unbroken 1,500-character line. It now walks the live
document, and the same page comes back as 93 lines with 70 links.

Links are not free. Measured on five saved pages, as characters of extracted
text, `dom` before → after:

| page | before | after | links |
|---|---|---|---|
| xiaohongshu search | 1,502 | 11,042 | 70 |
| Hacker News front page | 3,767 | 16,266 | 228 |
| Wikipedia article | 75,174 | 130,690 | 741 |
| Python docs | 42,585 | 49,691 | 97 |
| react.dev tutorial | 67,898 | 69,142 | 14 |

The blowup tracks link density, which is exactly the axis along which links are
worth having: the pages that grow most are the ones that are *made of* links.
For scale, `article` on that Wikipedia page — which has always kept its links —
is 160,317 characters, larger than the linked DOM text. Bounding a fetch's
output is a real problem, but it is not this knob's job.

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

Both modes recovered identical event counts on Calendar (16 / 4), which is why
`auto` never once fired its fallback on these. Don't assume an app-shaped page
needs `dom` without measuring — and note the pages these numbers were taken on
are all documents. A search result page is where `article` loses outright.
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

### Detection is one dumb tier

**Known signatures** — Cloudflare, Turnstile, reCAPTCHA, hCaptcha, Arkose,
DataDome, PerimeterX, login walls. Cheap, exact, and the only thing that can
mark a page blocked. `agent-browser status` prints the table; it is fixed at
build time and is the same on every machine.

There was a second tier: anything extracting to under `--min-words` was
treated as blocked, screenshotted, and turned into a proposed signature. It is
gone. A signature match is a positive claim made from things the caller cannot
see — a third-party challenge iframe, a title, a URL. A low word count is not:
its whole evidence is a number already reported back as `char_count`, so the
tool was ruling on something the caller could see for itself, and ruling badly.

It was wrong in three ways at once. The count came from whichever extractor
`--mode` selected, so the same page came back as content or as blocked
depending on a presentation choice. It fired on every legitimately short page —
`fetch https://example.com`, thirty-odd words, used to put the browser on your
screen and block for five minutes. And the rules it guessed were worse than
nothing: a thin page once taught it `^Example Domain`, which then "blocked"
every later fetch of that site.

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
    AGENT_BROWSER_HANDOFF_TIMEOUT  seconds to wait for you (default 300)
    AGENT_BROWSER_WM        window backend
    AGENT_BROWSER_VNC_HOST/PORT    default 127.0.0.1:5900 (websocket)
    AGENT_BROWSER_NOVNC_PORT       viewer page (default 6080)
    AGENT_BROWSER_NOVNC     noVNC install dir (the flake sets this)
    AGENT_BROWSER_VIEWER    browser for the viewer window (default: the Chrome above)
    AGENT_BROWSER_VNC_SCALE nested output scale (default: the host screen's)

## Install

    nix develop            # dev shell: cage, wayvnc, noVNC, python + deps
    nix run .              # run the CLI directly
    nix run .#mcp          # run the MCP server

The flake pins everything except the browser, Python dependencies included --
`nix/python-overlay.nix` carries the two that nixpkgs lacks or has too old,
and `nix build` needs neither a network nor a compiler. Chrome deliberately comes from
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
