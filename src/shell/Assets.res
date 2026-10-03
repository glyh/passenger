// The files that ship beside the code, and how to read one.
//
// Everything here is a template or a page rather than code: the viewer a human
// takes the browser over in, and the session's own shell script, sway config and
// IME snippet. They are *files* rather than string literals so a shell script can
// be read, diffed and linted as one -- which is the C# side's reasoning, kept.
//
// What changes is how they are found. There they were embedded resources, so a
// single-file publish still carried them; here, since ticket 083, they are
// embedded again -- through a bun file-attribute import in `AssetsEmbedded.mjs`
// beside this file -- because a `bun build --compile` binary has no `assets/`
// directory to find. `import.meta.dirname` is `/$bunfs/root` there, and the
// walk that used to answer `root()` threw "no assets directory above
// /$bunfs/root" out of `Browser.start()`, so every `openLane` and `script`
// call returned Internal error and no Chrome came up. Under plain node the same
// walk worked, which is exactly why the breakage was compile-only and silent.

@val @scope("import.meta") external dirname: string = "dirname"

/// name (under `assets/`) -> a readable path to that asset's bytes. See
/// `AssetsEmbedded.mjs` for why this is a hand-written `.mjs` and why the two
/// runtimes fill it by two different mechanisms.
@module("./AssetsEmbedded.mjs") external embeddedPaths: dict<string> = "paths"

/// The readable path an asset resolves to through the embedded map, or `None`.
/// `read` falls back on this when there is no real `assets/` tree to join
/// against; a test pins that the map covers all four names.
let embedded = name => embeddedPaths->Dict.get(name)

/// Where `assets/` is -- the directory *itself*, not the `web/` or `session/`
/// subdirectory one of the four files lives in, because `read` joins this with
/// a path under `assets/` (e.g. `web/viewer.html`).
///
/// Derived from an embedded path since ticket 083, and the arithmetic rests on
/// one assumption worth spelling out: a file-attribute import yields a readable
/// path, and that path either keeps the source layout or does not.
///
///   - Any run from source (node, or bun without `--compile`): the path is the
///     real file, `<...>/assets/web/viewer.html`. Stripping the `web/viewer.html`
///     tail -- two `dirname`s -- lands on `assets/`. One `dirname` would land on
///     `assets/web`, which is the bug the tail check exists to avoid.
///   - A compiled binary: bun flattens every embedded file into one directory
///     under a mangled `<stem>-<hash>.<ext>` name (`/$bunfs/root/viewer-a1b2.html`),
///     so there is no `web/` tail to strip and two `dirname`s would walk out of
///     the filesystem entirely. One `dirname` is then the directory that
///     contains all four embedded files.
///
/// If bun ever preserves the source layout inside the binary, the tail branch
/// already covers it; if it ever mangles differently, the flat branch still
/// names the directory the files are actually readable from.
let root = () =>
  switch embedded("web/viewer.html") {
  | Some(path) =>
    path->String.endsWith("web/viewer.html") ? Fs.dirname(Fs.dirname(path)) : Fs.dirname(path)
  | None =>
    // No embedded map in play: the pre-083 walk, unchanged. Find `assets/` by
    // walking up from this module rather than counting a fixed number of `..` --
    // that spelling was wrong within a day of being written, when the sources
    // moved from one flat `src/` into `src/core`, `src/shell` and the rest, and
    // a hard-coded depth would have gone on resolving to a directory that no
    // longer holds anything.
    let found = ref(None)
    let at = ref(dirname)
    for _ in 0 to 4 {
      if found.contents->Option.isNone {
        let candidate = Fs.join(at.contents, "assets")
        if Fs.existsSync(candidate) {
          found := Some(candidate)
        } else {
          at := Fs.dirname(at.contents)
        }
      }
    }
    switch found.contents {
    | Some(dir) => dir
    | None => throw(Failure("no assets directory above " ++ dirname))
    }
  }

/// An asset, by its path under `assets/`.
///
/// Missing is a packaging error that got as far as running, not a condition any
/// caller can do anything about, so it throws rather than answering `None`.
///
/// The tree join first: wherever a real `assets/` directory exists (node, and
/// any run from source) this is the whole mechanism and the bytes are the ones
/// on disk. The embedded map second, because inside a compiled binary the join
/// cannot work -- bun flattens the four files under mangled names, so nothing
/// sits at `root()/web/viewer.html` -- and the map is where `root()`'s own
/// answer came from.
let read = name =>
  switch Fs.readText(Fs.join(root(), name)) {
  | Some(text) => text
  | None =>
    switch embedded(name)->Option.flatMap(Fs.readText) {
    | Some(text) => text
    | None => throw(Failure(`${name} is missing from the assets directory`))
    }
  }
