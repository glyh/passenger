---
id: 083
title: Ship one file with bun, and stop needing nix
labels: [wayfinder:grilling]
status: open
assignee:
blocked_by: [082]
---

## Question

Ship `passenger` as one file, with no nix, using **bun**. The owner's decision,
2026-10-01, taken after the alternatives were measured to the point of a
runner-up. What remains is not *whether* but *how* — and two of the hows are
still unmeasured.

## The decision, and the measurements under it

All on this machine, 2026-10-01, Node 24.19.0, bun 1.3.14 installed and 1.4.2
downloaded into `/tmp` (the installed bun was left alone):

| | node 24.19.0 | bun 1.3.14 | bun 1.4.2 | Node SEA |
|---|---|---|---|---|
| `playwright-core` `connectOverCDP` | ok, 23 ms | **fails**, 30 s timeout | **ok, 23 ms** | ok |
| the same in a compiled binary | — | fails identically | **ok** | ok |
| `node:vm` `createContext`+`runInContext` | ok | ok | ok | ok (CJS) |
| `node:sqlite` `DatabaseSync` | ok | **absent** | **ok, node-compatible** | ok |
| ESM entry | native | native | native | **no — CJS only** |
| single-file size | — | — | 81,315,296 B | 75,043,984 B |

- **1.3.14 fails and 1.4.2 does not.** Root cause: bun's `node:http` client
  never delivered the `'upgrade'` event for `101 Switching Protocols`, so every
  `ws`-based Node client died — playwright's bundled one, and a scratch
  `ws@8.22.0` identically. Upstream: #32204 (`node:http: emit 'upgrade' on
  ClientRequest for 101 responses`) closed **unmerged**; #31792 (`ws
  'unexpected-response' is not implemented, breaks chrome-devtools-mcp and
  puppeteer`) closed **completed**, 2026-07-29. The installed 1.3.14 is
  2026-05-13, three minors and ~115 days behind. **The floor is 1.4.2, the first
  version measured good, and it must be checked at build time rather than
  assumed** — the version is load-bearing, not a preference.
- **`src/runtime/Sqlite.res` is not rewritten.** `node:sqlite` exists on 1.4.2
  and behaves as node's does, bare `{id}` keys against `$id` included, so the
  existing binding runs unchanged under both runtimes. The trap is
  `bun:sqlite`, which 1.4.2 does not change: bare keys bind nothing, `INSERT`
  writes NULLs, nothing throws, and a `SELECT` returns `[]`. Do not adopt it as
  an optimization; and if anyone ever does, the keys must carry the `$`.
- **SEA was the runner-up and is not wrong** — a smaller file at a higher build
  cost. Its main must be CJS (`embedderRunCjs`; the SEA config has no format
  field and the blob carries no format byte), so the ESM output needs an esbuild
  step before the blob and postject after it. bun takes ESM natively, in one
  command. bun's argv shape also already matches node's, so nothing extra.
- **Neither is static.** bun links glibc (newest required symbol `GLIBC_2.17`,
  so roughly 2013 onwards) and SEA is a copy of node with one extra LOAD
  segment. A truly static binary is not on offer from either; "one file that
  needs a 2013-era libc" is what this buys.

## What "no nix" actually means, which is the honest half

nix is not a node wrapper here. The union closure of what it puts on `PATH`
plus node plus noVNC is **571 MiB across 209 store paths**, and `flake.nix`
says of the compositor and its VNC server that they *"are the packages you
would otherwise install with a system package manager"*. So:

- **no nix** = distro packages for `sway`, `swaymsg`, `wayvnc`, `wlr-randr`,
  `wayland-info` and `dbus`, noVNC vendored instead of set through
  `PASSENGER_NOVNC`, and a bun ≥ 1.4.2. The 571 MiB does not shrink, it changes
  owner. Largest measured entries: nodejs-slim 87, icu4c 40, glibc 36, ffmpeg
  34 + x265 24 (wayvnc's encoder), systemd-minimal 24 (dbus), librsvg 16.
- **one file** = bun `--compile` for our half only. Chrome stays the host's, by
  design — 061 declined to pin it because the version string is a fingerprint
  field — and a DRM render node plus a desktop Wayland session remain
  requirements. 059 recorded the same floor: *"a DRM render node and a host
  Chrome are requirements of the design, not of the build."* Handing someone
  one file still means handing them a prerequisite list.

## Open, and unmeasured

1. **The assets.** `Assets.root()` walks up from `import.meta.dirname` looking
   for a real `assets/` directory, and `novncRoot()` wants `core/rfb.js` on a
   real path. Inside a compiled binary `import.meta.dirname` is `/$bunfs/root`,
   so both break. Either embed — bun's file embedding, then teach both readers
   to use it — or ship `assets/` and noVNC beside the binary and accept that it
   is not literally one file. **Measure it**, including whether the four assets
   and the noVNC tree survive `--compile` when imported.
2. **Whether the real app loads under 1.4.2 at all.** No probe has loaded
   `passenger` itself — only the three primitives. This needs
   [082](082-watchdog-reexec-as-a-flag.md) first, since the watchdog re-exec is
   broken in any single-file form.
3. **Whether the flake stays for the dev shell.** Nothing here says to delete
   it. A `nix develop` that still works is not the same as a shipping story
   that needs nix.

## What must not change

The warm logged-in profile, the host's Chrome, and stealth. A single file is a
packaging change, and must not become a reason to bring a browser or a profile
along with it.

## Not this

[082](082-watchdog-reexec-as-a-flag.md) is the prerequisite;
[085](085-cdp-path-has-no-test.md) is the guard that makes the version floor
enforceable rather than merely written down.
