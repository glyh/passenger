// Stopping the browser when nobody has used it for hours (ticket 076).
//
// Chrome is started on demand and nothing else ever ended it, so a laptop
// that read one page at 10:00 ran a full Chrome, a compositor and a VNC
// server until shutdown -- watts spent on nothing, silently, with no window
// on screen to remind anyone. This module holds the rules the reap runs by
// and the teardown it runs; `src/cli/Watchdog.res` is the detached process
// that carries them.
//
// **Why the rules are here and the carrier is elsewhere.** The carrier was
// grilled into its final shape (076, as amended): not a lingering serve
// process -- that bets the reap on *how a client tears the server down*,
// and the owner declined to assume anything about downstream -- but a
// process of our own, spawned beside the Chrome it watches, indifferent to
// whatever kills its spawner. What that carrier cannot afford is this
// module's dependency chain: Playwright reaches here through `Browser` and
// `Session`, so everything the watchdog needs lives below those -- sqlite
// and the CDP HTTP endpoint, never `Pw`. That is also why the shared
// teardown lives here rather than in `Browser`, whose `stop` now delegates
// to it: one teardown, two callers, and the lean one gets to stay lean.
//
// **The decision is a function of its arguments**, in the `Detect` manner:
// facts in, verdict out, no browser to start and no clock to sleep out.
// The facts are the registry's -- the same wall clock every writer shares.

/// How much longer a browser must sit *unanswerable* before it is reaped
/// blind -- without the tab answer that the sighted reap insists on. A
/// wedged Chrome never answers the occupied question, so the sighted path
/// skips it forever; this is the owner's ruling (076, amended) that a full
/// blind horizon of silence is evidence enough to close it anyway. Derived
/// from the idle horizon rather than a second knob, so `never` cannot be
/// argued with by half a setting.
let blindMultiple = 8

/// Whether Chrome answered the tabs question this round. `Known` is the
/// answer, `Unknown` is Chrome's silence -- the distinction `occupied`
/// collapses for `stop` and the reaper lives on: a clock that cannot see
/// that the lanes are empty does not know the browser is idle.
type occupied =
  | Known(array<(string, int)>)
  | Unknown

type verdict =
  | Wait
  | Fire
  | FireBlind

/// One round of the question "does the browser go now".
///
/// `Fire` wants all three facts agreeing: the horizon passed, no lane holds
/// a live tab, nobody holds the screen. `FireBlind` wants the same two
/// registry facts plus *two* clocks run out -- the idle clock, so nobody
/// even tried the browser lately (a wedged browser still gets touched by
/// every failing call, `Service.run` touches on entry -- so retries read as
/// use and hold the blind reap off), and the silence clock, so the browser
/// has been unanswerable for the whole blind horizon and this is not a
/// five-second stall. Registry claims stop even the blind reap: "Chrome
/// won't answer" is not "sqlite won't read", and a claim standing for a
/// live viewer window means someone is looking at the thing.
let decide = (~now, ~newest, ~idleStopS, ~claims, ~occupied, ~blindSince) => {
  if idleStopS == 0 {
    // Never means never, and it reaches here only if a watchdog was spawned
    // with the setting flipped underneath it: the summoner refuses first.
    Wait
  } else {
    let idle = now -. newest
    let blind = Int.toFloat(idleStopS * blindMultiple)
    switch occupied {
    | Known(occupied) =>
      if idle >= Int.toFloat(idleStopS) && claims->Array.length == 0 && occupied->Array.length == 0 {
        Fire
      } else {
        Wait
      }
    | Unknown =>
      switch blindSince {
      | Some(since) if idle >= blind && now -. since >= blind && claims->Array.length == 0 =>
        FireBlind
      | _ => Wait
      }
    }
  }
}

/// The silence clock's transition: first unanswered round starts it, the
/// first answer clears it. Kept beside `decide` and pure for the same
/// reason -- the watchdog holds it across ticks, but the rule for moving it
/// is a fact about the decision, not about the process.
let nextBlindSince = (~occupied, ~current, ~now) =>
  switch occupied {
  | Unknown => Some(current->Option.getOr(now))
  | Known(_) => None
  }

// --- summoning the carrier --------------------------------------------------

@val @scope("process") external execPath: string = "execPath"

/// The flag `src/cli/Entry.res` dispatches on to the watchdog body, spelled the
/// same on both sides. Two literals rather than one shared constant, and this
/// is deliberate: the entry may not be imported here (it dispatches at import
/// time), this module may not be imported there (the entry keeps an empty
/// static graph), and a shared module for one string is a third file to keep
/// honest. The two spellings name each other in their comments; that is the
/// coupling.
let watchdogFlag = "--watchdog"

/// Where the dispatcher entry sits, on disk. Derived from *this module's* own
/// file rather than from `argv[1]`: `argv[1]` is whoever was run, and that is
/// not always the entry -- `node live/LiveWatchdog.res.mjs` summons this too,
/// and spawning `argv[1]` with the flag there would re-run the summoner instead
/// of the reaper. In a single-file build this path names nothing on disk, and
/// that is fine: the compiled forms re-exec their own binary, whose entry *is*
/// the dispatcher, and carry this string as one more inert argv (see the spawn
/// shape below).
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
let hereUrl: unit => string = %raw(`() => import.meta.url`)
let entry = () => Fs.join(Fs.dirname(fileURLToPath(hereUrl())), "../cli/Entry.res.mjs")

/// Spawn the reaper for this browser, unless one is already watching or the
/// setting says never.
///
/// Spawned by `Browser.start` -- in the "already running" branch too, since
/// a browser a previous client left behind still deserves a reaper even
/// when its own died with something. Started from *this* process so its
/// environment is this browser's: `PASSENGER_STATE` and the port captured
/// at spawn are the ones the watched Chrome answers on, by construction
/// rather than by re-reading anything. A reaper that could not start is no
/// reason to fail a start that did -- the cost is the old world, a browser
/// nothing stops.
///
/// One spawn shape for every runtime: `execPath`, then the entry path, then the
/// flag. Under node the entry path is the script node runs and the flag lands at
/// argv[2]; under `bun build --compile` and Node SEA the script-slot argument is
/// carried as one more user argument and the flag lands at argv[3] (measured,
/// ticket 082's table). The dispatcher scans the first few argv entries for a
/// flag it knows instead of assuming one index, so this spawn is never rewritten
/// per runtime and `Webserve`'s re-exec is covered by the same tolerance. The
/// other shape the ticket offered -- branching here on whether `argv[1]` is a
/// file on disk to pick between `[argv[1], flag]` and `[flag]` -- is rejected
/// here on measured grounds: SEA's `argv[1]` is the binary itself, a file on
/// disk, and the `live/` summons have a file at `argv[1]` that is not the entry
/// at all.
let summon = () => {
  if Config.idleStopS.contents == 0 {
    ()
  } else if NestedSessions.watchdogPid()->Option.isSome {
    ()
  } else {
    switch Proc.detach(execPath, [entry(), watchdogFlag]) {
    | Some(pid) => NestedSessions.recordWatchdog(pid)
    | None => ()
    }
  }
}

// --- the sweep, with its presentation half ----------------------------------

/// The sweep every lane-taking call already runs, with the piece that makes
/// collecting a lane hold for the screen: a lane whose clock ran out takes
/// its claim with it, and nothing else would then put the viewer away -- so
/// the sweep that frees the last claim is also what dismisses it.
///
/// Moved here from `Main.housekeep` so the reaper's tick can run it too:
/// `openLane` promises a lane "collects itself after 30 minutes of no
/// calls", and with no call arriving, nothing used to collect it. The
/// promise is kept on the tick now, in the hours before the horizon.
let sweepPresentation = async () => {
  let holders = Lanes.screenClaims()
  let collected = await Lanes.sweep()
  if holders->Array.some(h => collected->Array.includes(h)) && Lanes.screenClaims()->Array.length == 0 {
    Present.select().dismiss()
  }
}

// --- the teardown -----------------------------------------------------------

/// Everything this tool spawned, taken down.
///
/// The inventory, named (ticket 076): the viewer window (`Present`'s
/// detached host browser, pid recorded), the viewer page server
/// (`Webserve`'s detached re-exec, pid recorded since 076 -- `ensure` used
/// to drop it, and nothing anywhere killed it), Chrome (by command line,
/// scoped to this tool's own profile directory), and the compositor and
/// VNC server (by the session record, with 024's SIGTERM-to-SIGKILL
/// escalation). One function, two callers: the reaper, and `passenger
/// stop` -- which used to name only the last three, and so left the window
/// showing a dead socket and the page server serving it until logout.
let takeDown = async () => {
  Present.select().dismiss()
  switch NestedSessions.viewerServerPid() {
  | Some(pid) => NestedSessions.terminate(pid)
  | None => ()
  }
  NestedSessions.clearViewerServer()
  NestedSessions.pidsRunning(`--user-data-dir=${Config.profileDir()}`)->Array.forEach(
    NestedSessions.terminate,
  )
  await NestedSessions.teardown()
}

// --- the note ---------------------------------------------------------------

let noteFile = () => Fs.join(Config.stateDir.contents, "idle-stop")

let nowIso = () => Date.make()->Date.toISOString

/// What happened, in one clause -- the ping and the note say the same thing,
/// so a human comparing the desktop notification with `browserStatus` is
/// comparing two spellings of one fact.
let describe = (~blind, ~idleS) => {
  let mins = Float.toInt(idleS /. 60.0)
  blind
    ? `chrome had not answered for ~${mins->Int.toString} min, likely wedged`
    : `nobody had used it for ${mins->Int.toString} min`
}

/// Written *before* the teardown, deliberately: the teardown's SIGKILL
/// escalation can take seconds, and the note is the only explanation a
/// caller gets if the process dies mid-way. Deliver-once (076, amended):
/// the note is consumed by the one error that needs it -- `laneNotFound`,
/// at the tool door in `Main` -- read passively by `browserStatus`, cleared
/// by a human `passenger stop`, overwritten by the next reap. Never cleared
/// by a start, which is what lets it survive the very restart that erased
/// the lane it explains.
let writeNote = (~blind, ~idleS) => {
  Fs.mkdirp(Config.stateDir.contents)
  Fs.writeFileSync(
    noteFile(),
    `browser stopped at ${nowIso()} -- ${describe(~blind, ~idleS)}; ` ++
    "the next call starts a fresh one; open a new lane",
  )
}

/// Read without consuming -- `browserStatus` reports it however often it is
/// asked; a read is not a delivery.
let peekNote = () => Fs.readText(noteFile())->Option.map(t => t->String.trim)

/// Read and consume. The one deleter that is not a human: the note exists
/// to explain a specific surprise, and it is delivered at that surprise or
/// not at all. A second caller whose lane died the same death gets the bare
/// error -- one delivery is one delivery, the owner's ruling.
let takeNote = () => {
  let note = peekNote()
  note->Option.forEach(_ => Fs.delete(noteFile()))
  note
}

/// A human stopped the browser on purpose; no explanation is owed.
let forgetNote = () => Fs.delete(noteFile())
