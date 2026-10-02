// The one entry point (ticket 082): it owns the re-exec flags and reaches every
// body through a dynamic `import()`.
//
// **Why a dispatcher and not a flag in `Main`.** The watchdog process must not
// reach Playwright -- it sits still for hours and Playwright hangs off `Session`
// -- and `Main`'s static graph does (31 modules, playwright-core through
// `Session.res.mjs`), while the watchdog's does not (20, clean). A `--watchdog`
// flag handled by `Main` would hand the reaper exactly what the three seams in
// `Browser`, `Present` and `Reaper` keep out of it. So this file holds no static
// graph at all: it reads the flag and *dynamically* imports the body it names.
// Dynamic `import()` is the whole mechanism -- it keeps the three graphs apart
// while one file is the entry -- and `test/ImportGraph_test.res` walks the
// emitted static imports of this file and of `Watchdog.res.mjs` and fails if
// either ever reaches playwright-core.
//
// **The flag sits at a runtime-dependent argv position**, measured (082):
//
//     node          execPath + [entry, flag]  ->  flag at argv[2]
//     bun compiled  execPath + [entry, flag]  ->  flag at argv[3]
//     Node SEA      execPath + [entry, flag]  ->  flag at argv[3]
//
// because the compiled forms carry the script-slot argument as one more user
// argument while node runs it as the script. So this looks through the *first
// few* argv entries for a flag it knows rather than at one index. That single
// tolerance also covers `Webserve`'s own `--serve-viewer` re-exec, whose spawn
// shape ([entry, flag, port]) shifts the same way -- the dispatcher is written
// once instead of each spawn branching on its runtime.

/// The flags this entry dispatches on. `watchdogFlag` is spelled again in
/// `Reaper.summon` and `serveViewerFlag` is `Webserve.serveFlag`: two literals
/// each rather than one shared constant, because this file may not import the
/// summoner (it dispatches at import time) nor the server (the empty static
/// graph is the whole point), and neither may import this one. Each side names
/// the other where it spells the flag; that comment is the coupling.
let watchdogFlag = "--watchdog"
let serveViewerFlag = "--serve-viewer"

@val @scope("process") external argv: array<string> = "argv"

// The three bodies, each behind its own dynamic import. The specifiers are
// relative to this file, and raw because `import()` is syntax rather than a
// function this compiler binds -- an external cannot name it, and the syntax
// does not survive being put in a variable.
let importWatchdog: unit => promise<unit> = %raw(`() => import("./Watchdog.res.mjs")`)
let importServer: unit => promise<unit> = %raw(`() => import("./Main.res.mjs")`)

type serveViewer = {serveIfAsked: array<string> => bool}
let importServeViewer: unit => promise<serveViewer> = %raw(`() => import("../shell/Webserve.res.mjs")`)

/// Dispatch on the first known flag among the first few argv entries. No known
/// flag means the server: `passenger serve`, `show`, `stop` and the rest reach
/// `Main`, which parses them itself -- this file never parses a command.
let main = async () => {
  let args = argv->Array.slice(~start=2, ~end=argv->Array.length)
  let heads = args->Array.slice(~start=0, ~end=3)
  switch heads->Array.findIndexOpt(a => a == watchdogFlag || a == serveViewerFlag) {
  | Some(i) if heads->Array.getUnsafe(i) == watchdogFlag =>
    let _ = await importWatchdog()
  | Some(i) =>
    let body = await importServeViewer()
    let _ = body.serveIfAsked(args->Array.slice(~start=i, ~end=args->Array.length))
  | None =>
    let _ = await importServer()
  }
}

main()->Promise.ignore
