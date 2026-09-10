// The carrier for the idle reap (ticket 076, built in 077).
//
// A process of our own, spawned beside the Chrome it watches by
// `Browser.start`, and indifferent to whatever kills its spawner. That was
// the grilled shape: a reap that lingers inside the serve process bets on
// *how a client tears the server down*, and nothing downstream may be
// assumed.
//
// **What it must not import.** The rules live in `Reaper` precisely so this
// file can reach them without reaching Playwright: everything named here
// bottoms out in sqlite, `notify-send` and Chrome's CDP HTTP endpoint. A
// stray `Session` or `Browser` here would pull Playwright into a process
// whose whole job is to sit still for hours -- which is why `Browser.stop`
// delegates to `Reaper.takeDown` rather than the other way round, and why
// `Present.unfullscreen` is a seam.
//
// Nothing is written to stdout or stderr: `Proc.detach` sends both to
// /dev/null, so the note and the desktop ping are the only things this
// process ever says.

/// Long enough that hours of watching cost nothing, short enough that the
/// horizon is not overshot by much. The horizon is hours; a minute of slack
/// on it is not a number anybody can feel.
let tickMs = 60_000

@val @scope("process") external exit: int => unit = "exit"

/// One round. Returns false when there is nothing left to watch.
///
/// The order is deliberate. The liveness check comes first, so a browser
/// somebody already stopped costs one HTTP request and ends this process
/// rather than a decision made about a corpse. The sweep comes next, because
/// a lane collected on this tick is a lane that no longer holds a tab, and
/// the reap should see the registry as a call would have left it -- without
/// this, `openLane`'s promise that a lane "collects itself after 30 minutes"
/// was kept only by the next call, and with no next call there was none.
/// The stale claim goes last before the facts for the same reason it is
/// dropped in `stop`: a `show` window closed by hand leaves a claim that
/// would otherwise hold the reap off forever.
let tick = async blindSince =>
  if !(await Targets.isUp()) {
    NestedSessions.clearWatchdog()
    None
  } else {
    await Reaper.sweepPresentation()
    Present.dropStaleHumanClaim(Present.select())

    let occupied = switch await Lanes.occupiedKnown() {
    | Some(lanes) => Reaper.Known(lanes)
    | None => Reaper.Unknown
    }
    let now = Lanes.now()
    let newest = Lanes.newestTouch()
    let verdict = Reaper.decide(
      ~now,
      ~newest,
      ~idleStopS=Config.idleStopS.contents,
      ~claims=Lanes.screenClaims(),
      ~occupied,
      ~blindSince,
    )

    switch verdict {
    | Reaper.Wait => Some(Reaper.nextBlindSince(~occupied, ~current=blindSince, ~now))
    | Fire | FireBlind =>
      let blind = verdict == Reaper.FireBlind
      let idleS = now -. newest
      // Ping first, note second, teardown last -- each survives the failure
      // of the one after it, and the teardown's SIGKILL escalation is the
      // only step that can take seconds.
      Notify.desktop.notify("passenger", `browser stopped -- ${Reaper.describe(~blind, ~idleS)}`)
      Reaper.writeNote(~blind, ~idleS)
      // What would not go is nobody's to hear: this process has no streams.
      let _ = await Reaper.takeDown()
      NestedSessions.clearWatchdog()
      None
    }
  }

/// Watch until there is nothing to watch, then go.
///
/// A tick that throws does not end the watch: sqlite is contended by every
/// other process on this machine and a locked read is a bad reason to leave
/// a browser running until logout. The silence clock is left where it was,
/// so a round that could not be taken is neither evidence of silence nor
/// evidence against it.
let rec watch = async blindSince => {
  let next = switch await tick(blindSince) {
  | outcome => outcome
  | exception _ => Some(blindSince)
  }
  switch next {
  | None => exit(0)
  | Some(blindSince) =>
    await Timers.sleep(tickMs)
    await watch(blindSince)
  }
}

watch(None)->Promise.ignore
