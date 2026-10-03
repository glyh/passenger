// The four assets as bun file-attribute imports: name -> readable path.
//
// **Why this file is hand-written JavaScript.** ReScript has no syntax for an
// import attribute -- `@module` emits a plain static import and there is no
// `with { type: "file" }` clause anywhere in the surface language -- so the
// attribute has to live in a `.mjs` this module reaches through `@module`.
//
// **Why the imports are dynamic and guarded rather than four static imports.**
// Plain node cannot evaluate `import x from "./session.sh" with { type: "file" }`
// at all: it ignores the attribute and dies on ERR_UNKNOWN_FILE_EXTENSION,
// and this graph runs under node whenever the suite does. A static import would
// poison `npm test` and every `node src/cli/Entry.res.mjs` run. The guard is a
// runtime check, but the *specifiers* are still literals, which is the half bun's
// bundler needs: `bun build --compile` sees the `import(..., { with: ... })` at
// build time and embeds the files (measured: Bun.embeddedFiles goes 0 -> 4).
//
// **What each branch yields is the same thing: a readable path to the same
// four files.** Under bun it is the embedded copy -- inside a compiled binary
// that is `/$bunfs/root/<stem>-<hash>.<ext>`, flat and mangled, which is why
// `Assets.read` cannot join under `Assets.root()` there and consults this map
// instead. Under node it is the file on disk in `assets/`, so node reads
// byte-identical content by either route.

import { fileURLToPath } from "node:url";

export const paths = {};

if (typeof Bun !== "undefined") {
  paths["session/session.sh"] = (await import("../../assets/session/session.sh", { with: { type: "file" } })).default;
  paths["session/sway.conf"] = (await import("../../assets/session/sway.conf", { with: { type: "file" } })).default;
  paths["session/ime.sh"] = (await import("../../assets/session/ime.sh", { with: { type: "file" } })).default;
  paths["web/viewer.html"] = (await import("../../assets/web/viewer.html", { with: { type: "file" } })).default;
} else {
  // node: no file-attribute imports here, so resolve the same four paths off
  // disk relative to this file -- the same anchor the old walk-up used, just
  // arrived at directly.
  for (const [name, rel] of [
    ["session/session.sh", "../../assets/session/session.sh"],
    ["session/sway.conf", "../../assets/session/sway.conf"],
    ["session/ime.sh", "../../assets/session/ime.sh"],
    ["web/viewer.html", "../../assets/web/viewer.html"],
  ]) {
    paths[name] = fileURLToPath(new URL(rel, import.meta.url));
  }
}
