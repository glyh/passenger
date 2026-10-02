// The compiled import graphs, walked as text (ticket 082).
//
// The watchdog sits still for hours and must not load Playwright to do it: the
// reaper reaches the browser over Chrome's CDP HTTP endpoint and sqlite, never
// through `Session`, and three comments (`Browser`, `Present`, `Reaper`) say
// why that separation is load-bearing. The property is about the *emitted*
// `.res.mjs`, not the source, so this walks the `from "..."` specifiers of the
// build output transitively and asserts what the closure reaches. Dynamic
// `import()` is invisible to the walk on purpose -- that is the mechanism
// keeping the graphs apart (`Entry.res` must reach three bodies and statically
// import none of them). `npm test` builds first; this reads the build output.
//
// No dependency: `Fs` is node's filesystem, bound in `src/runtime`.

/// The static import specifiers of one emitted module: every `from "..."`.
let specifiers = text => {
  let parts = text->String.split("from \"")
  parts
  ->Array.slice(~start=1, ~end=parts->Array.length)
  ->Array.map(part => part->String.split("\"")->Array.getUnsafe(0))
}

/// Everything `file`'s static imports reach transitively, as cwd-relative
/// paths. `Fs.join` normalises `..`, so the same file always names itself the
/// same way and the visited check is an equality check.
let rec reach = (file, seen) =>
  if seen->Array.includes(file) {
    seen
  } else {
    let seen = Array.concat(seen, [file])
    switch Fs.readText(file) {
    | None => seen
    | Some(text) =>
      specifiers(text)->Array.reduce(seen, (seen, specifier) =>
        specifier->String.startsWith(".") ? reach(Fs.join(Fs.dirname(file), specifier), seen) : seen
      )
    }
  }

/// The package specifiers the closure's imports name -- bare ones only, which
/// is where `playwright-core` would appear. One call per file, not once over
/// the closure's text, so a specifier cannot be read across a file boundary.
let packages = files =>
  files->Array.flatMap(file =>
    switch Fs.readText(file) {
    | None => []
    | Some(text) => specifiers(text)->Array.filter(s => !(s->String.startsWith(".")))
    }
  )

let reachesPlaywright = files => packages(files)->Array.filter(p => p->String.includes("playwright"))

let watchdogGraph = reach("src/cli/Watchdog.res.mjs", [])
let entryGraph = reach("src/cli/Entry.res.mjs", [])

T.test("the watchdog's static graph never reaches Playwright", () =>
  T.equal(reachesPlaywright(watchdogGraph), [])
)

T.test("the dispatcher's static graph never reaches Playwright", () =>
  T.equal(reachesPlaywright(entryGraph), [])
)

T.test("the dispatcher does not statically import the server", () =>
  T.equal(entryGraph->Array.filter(f => f == "src/cli/Main.res.mjs"), [])
)

// The walk itself has teeth: a change that made `specifiers` stop matching
// would leave every closure empty and every assertion above vacuously green.
T.test("the walk is not vacuous", () =>
  T.ok(watchdogGraph->Array.includes("src/shell/Reaper.res.mjs"))
)
