#!/usr/bin/env bash
# One file with bun: compile src/cli/Entry.res.mjs into a single binary.
#
#     bash scripts/compile.sh [outfile]        # default: ./passenger
#     npm run compile                          # the same, through package.json
#
# The version floor is load-bearing, not a preference. 1.3.14 has no
# node:sqlite at all, and its node:http never emits 'upgrade' for 101 Switching
# Protocols, so every ws-based node client dies -- playwright's bundled one
# included, which is this app's whole CDP transport. 1.4.2 is the first version
# measured good (ticket 083); refuse anything older rather than shipping a
# binary that hangs 30s per connect.
#
# --external chromium-bidi is required: without it the bundler aborts on
# playwright's lazy BiDi require.
#
# This is an additional path, not a replacement: the nix dev shell, `npm test`
# and `node src/cli/Entry.res.mjs` all keep working exactly as before.
set -euo pipefail

cd "$(dirname "$0")/.."

floor="1.4.2"
version="$(bun --version)"
if [ "$(printf '%s\n%s\n' "$floor" "$version" | sort -V | head -n1)" != "$floor" ]; then
  echo "passenger needs bun >= $floor, found $version" >&2
  echo "1.3.14 has no node:sqlite, and its node:http never emits 'upgrade'" >&2
  echo "for 101 Switching Protocols -- which breaks CDP (playwright's ws" >&2
  echo "transport dies on every connect). The floor is measured, not a" >&2
  echo "preference: see docs/wayfinder/tickets/083-one-file-with-bun.md." >&2
  exit 1
fi

# Build first, like `npm test` does: a stale .res.mjs that still runs while its
# .res no longer compiles is the failure mode an in-source build invites.
npm run build

exec bun build --compile --external chromium-bidi src/cli/Entry.res.mjs --outfile "${1:-passenger}"
