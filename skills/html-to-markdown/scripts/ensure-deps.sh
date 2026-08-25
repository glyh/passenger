#!/usr/bin/env bash
# Install the converter's Node dependencies into a cache dir, once.
# Kept out of the skill directory so the skill works when installed read-only.
set -euo pipefail
CACHE="${HTML2MD_CACHE:-$HOME/.cache/html-to-markdown-skill}"
DEPS="defuddle turndown turndown-plugin-gfm jsdom"

write_loader() {
  cat > "$CACHE/loader.mjs" <<'JS'
export { Defuddle } from 'defuddle/node';
export { JSDOM } from 'jsdom';
export { default as TurndownService } from 'turndown';
export { gfm } from 'turndown-plugin-gfm';
JS
}

if [ -d "$CACHE/node_modules/defuddle" ] \
   && [ -d "$CACHE/node_modules/turndown" ] \
   && [ -d "$CACHE/node_modules/turndown-plugin-gfm" ] \
   && [ -d "$CACHE/node_modules/jsdom" ]; then
  write_loader
  echo "deps ready: $CACHE"
  exit 0
fi

command -v npm >/dev/null || { echo "npm not found; install Node.js first" >&2; exit 1; }
mkdir -p "$CACHE"
[ -f "$CACHE/package.json" ] || echo '{"name":"html-to-markdown-skill","private":true}' > "$CACHE/package.json"
echo "installing $DEPS into $CACHE ..." >&2
npm install --prefix "$CACHE" --no-audit --no-fund --loglevel=error $DEPS >&2
write_loader
echo "deps ready: $CACHE"
