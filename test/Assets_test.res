// The four assets must resolve wherever this runs -- node today, a bun
// `--compile` binary when it ships as one file.
//
// The regression this guards: `root()` used to walk up from
// `import.meta.dirname`, which finds `assets/` under node and finds nothing
// inside a compiled binary (`import.meta.dirname` is `/$bunfs/root` there), so
// `Assets.read` threw "no assets directory above /$bunfs/root", `Browser.start()`
// threw with it, and every `openLane`/`script` call returned Internal error --
// compile-only, and silent under `npm test` until the binary was measured.
// Resolution is now two routes with `read` trying both: the tree join where a
// real `assets/` directory exists, and the embedded map from
// `AssetsEmbedded.mjs` where it does not. This file pins all three shapes:
// `root()` is the `assets/` directory itself, `read` returns the expected bytes,
// and the embedded map covers every name with the same bytes.

let names = ["session/session.sh", "session/sway.conf", "session/ime.sh", "web/viewer.html"]

T.test("root() is the assets directory itself, not assets/web", () => {
  let root = Assets.root()
  // The shape of the requirement in one line: `read` joins `root()` with a path
  // under `assets/`, so `web/viewer.html` must exist at that join. A root of
  // `assets/web` -- the naive one-`dirname` reading of the embedded viewer's
  // path -- fails here, which is the arithmetic ticket 083 got wrong in draft.
  T.ok(Fs.existsSync(Fs.join(root, "web/viewer.html")))
  T.ok(Fs.existsSync(Fs.join(root, "session/session.sh")))
})

T.test("read returns the bytes of the named asset", () => {
  // Marker per file rather than one shared "non-empty": a swapped or truncated
  // asset that still reads as *something* is exactly the silent breakage the
  // two routes make possible, and only content catches it.
  T.ok(Assets.read("session/session.sh")->String.includes("wayvnc"))
  T.ok(Assets.read("session/sway.conf")->String.includes("default_border none"))
  T.ok(Assets.read("session/ime.sh")->String.includes("fcitx5"))
  T.ok(Assets.read("web/viewer.html")->String.includes("passenger"))
})

T.test("every asset also resolves through the embedded map", () => {
  // The compiled binary has no tree to join against, so this map is its whole
  // mechanism. Under node the same map points at the real files on disk, so
  // comparing against `read` checks that both routes name the same bytes -- and
  // that a name typo in `AssetsEmbedded.mjs` fails here instead of inside a
  // shipped binary.
  names->Array.forEach(name =>
    switch Assets.embedded(name) {
    | Some(path) => T.equal(Fs.readText(path), Some(Assets.read(name)))
    | None => T.equal(Assets.embedded(name)->Option.isSome, true)
    }
  )
})
