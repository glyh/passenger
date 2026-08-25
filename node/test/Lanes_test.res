// The lane registry, without a browser.
//
// Everything here is the table and its rules; nothing opens Chrome. What is
// left untested by that boundary is named at the bottom of ticket 040 --
// adoption against a real popup, the screen refcount across two live
// processes, and expiry actually closing tabs.
//
// The oracle is `tests/Passenger.Tests/LanesTests.cs`, all 26 cases. Two
// differences, both recorded rather than smoothed over:
//
//   - `Config.stateDir` is pointed at a temp path here, as `Sandbox` does on
//     the C# side, so these never touch a developer's real registry.
//   - The two cases that slept 1.1 seconds move the clock instead. `Lanes.clock`
//     is a ref for exactly this, and the suite is 2.2 seconds shorter for it.

@module("node:fs") external mkdtempSync: string => string = "mkdtempSync"
@module("node:os") external tmpdir: unit => string = "tmpdir"

Config.stateDir := mkdtempSync(tmpdir() ++ "/passenger-lanes-")

// Chrome's target list, without Chrome. Records what was closed.
type fake = {mutable ids: array<string>, mutable closed: array<string>, mutable wedged: bool}

let fake = {ids: [], closed: [], wedged: false}

let seam: Lanes.chromeTabs = {
  liveTabs: () =>
    fake.wedged
      ? throw(Errors.Passenger({code: DaemonNotRunning, message: "no daemon"}))
      : fake.ids,
  close: tab => {
    fake.closed = fake.closed->Array.concat([tab])
    fake.ids = fake.ids->Array.filter(t => t != tab)
    true
  },
  openers: () => Dict.make(),
}

// Each test starts on an empty table and a fresh browser, since the file and
// the fake are both shared.
let laneTest = (name, body) =>
  T.test(name, () => {
    Lanes.clock := (() => Math.floor(Date.now() /. 1000.0))
    Lanes.reset()
    Lanes.chrome := seam
    fake.ids = ["T1", "T2", "T3"]
    fake.closed = []
    fake.wedged = false
    body()
  })

let notFound = f =>
  switch f() {
  | _ => false
  | exception Errors.Passenger({code: LaneNotFound}) => true
  | exception _ => false
  }

laneTest("openLane mints distinct ids", () => {
  T.ok(Lanes.openLane() != Lanes.openLane())
})

laneTest("the reserved lane exists without being opened", () => {
  // `orphan` never expires: a TTL there would collect the tabs a human opened
  // during a handoff, which is what ticket 018 exists to prevent.
  T.equal(Lanes.require(Lanes.orphan).ttlS, Lanes.noTtl)
})

laneTest("an unknown lane is refused", () => {
  T.ok(notFound(() => Lanes.require("nobody")))
})

laneTest("a tab belongs to exactly one lane", () => {
  let first = Lanes.openLane()
  let second = Lanes.openLane()
  Lanes.adopt("T1", first)
  T.equal(Lanes.tabsOf(first), ["T1"])
  T.equal(Lanes.tabsOf(second), [])
  Lanes.adopt("T1", second)
  T.equal(Lanes.tabsOf(first), [])
  T.equal(Lanes.tabsOf(second), ["T1"])
})

laneTest("expiry needs quiet, not merely age", () => {
  // The bug this guards: a lane collected while its call was still running. A
  // `script` with a 600s budget outlives a 30-minute lane only if nothing
  // restarts the clock, so every call touches the lane on entry and on return.
  let lane = Lanes.openLane(~ttlS=60)
  let base = Math.floor(Date.now() /. 1000.0)
  T.equal(Lanes.expired(~at=base +. 61.0), [lane])
  Lanes.touch(lane)
  // The clock now runs from the touch, not from when the lane was opened.
  T.equal(Lanes.expired(~at=base +. 59.0), [])
})

laneTest("a lane with no TTL never expires", () => {
  let lane = Lanes.openLane(~ttlS=Lanes.noTtl)
  let base = Math.floor(Date.now() /. 1000.0)
  T.ok(!(Lanes.expired(~at=base +. 10000.0)->Array.includes(lane)))
})

laneTest("setTtl restarts the clock", () => {
  let lane = Lanes.openLane(~ttlS=60)
  Lanes.setTtl(lane, 7200)
  T.equal(Lanes.require(lane).ttlS, 7200)
  T.equal(Lanes.expired(~at=Math.floor(Date.now() /. 1000.0) +. 61.0), [])
})

laneTest("destroying a lane takes its rows with it", () => {
  let lane = Lanes.openLane()
  Lanes.adopt("T1", lane)
  Lanes.claimScreen(lane)
  Lanes.destroy(lane)
  T.ok(notFound(() => Lanes.require(lane)))
  T.equal(Lanes.owner("T1"), None)
  T.equal(Lanes.screenClaims(), [])
})

// --- what `stop` refuses on (057) ------------------------------------------

laneTest("occupied counts live tabs per lane and skips orphan", () => {
  let mine = Lanes.openLane()
  Lanes.adopt("T1", mine)
  Lanes.adopt("T2", mine)
  // Chrome is launched with about:blank and it lands here, so counting
  // `orphan` would mean a refusal that never lifts.
  Lanes.adopt("T3", Lanes.orphan)
  T.equal(Lanes.occupied(), [(mine, 2)])
})

laneTest("occupied ignores rows for tabs Chrome no longer holds", () => {
  let lane = Lanes.openLane()
  Lanes.adopt("T1", lane)
  fake.ids = fake.ids->Array.filter(t => t != "T1")
  // A row is not work. The sweep that would drop it may not have run.
  T.equal(Lanes.occupied(), [])
})

laneTest("occupied is empty when Chrome does not answer", () => {
  let lane = Lanes.openLane()
  Lanes.adopt("T1", lane)
  fake.wedged = true
  // The wedged browser is the case `stop` exists for: a check that cannot
  // complete must not be what stands in its way.
  T.equal(Lanes.occupied(), [])
})

laneTest("the reserved lane is emptied rather than removed", () => {
  Lanes.adopt("T1", Lanes.orphan)
  Lanes.destroy(Lanes.orphan)
  T.equal(Lanes.tabsOf(Lanes.orphan), [])
  T.equal(Lanes.require(Lanes.orphan).id, Lanes.orphan)
})

// --- reconciling ------------------------------------------------------------

laneTest("a tab Chrome no longer holds is forgotten", () => {
  let lane = Lanes.openLane()
  Lanes.adopt("GONE", lane)
  Lanes.reconcile([], Dict.make())
  T.equal(Lanes.tabsOf(lane), [])
})

laneTest("a popup joins the lane that opened it", () => {
  // window.open and target=_blank, which would otherwise leak. Such a target
  // has no row, so no lane can see it, no lane can close it, and the sweep
  // never reaches it -- the sweep collects lanes, not tabs.
  let lane = Lanes.openLane()
  Lanes.adopt("PARENT", lane)
  Lanes.reconcile(["PARENT", "POPUP"], Dict.fromArray([("POPUP", "PARENT")]))
  T.equal(Lanes.owner("POPUP"), Some(lane))
})

laneTest("a tab with no opener lands in orphan", () => {
  // A human opening tabs during a handoff. Chrome records no opener for them,
  // so there is nothing to trace and guessing would be a heuristic.
  Lanes.reconcile(["HUMAN"], Dict.make())
  T.equal(Lanes.owner("HUMAN"), Some(Lanes.orphan))
})

laneTest("a popup whose opener is unknown lands in orphan", () => {
  Lanes.reconcile(["POPUP"], Dict.fromArray([("POPUP", "VANISHED")]))
  T.equal(Lanes.owner("POPUP"), Some(Lanes.orphan))
})

laneTest("reconcile leaves settled tabs where they are", () => {
  let lane = Lanes.openLane()
  Lanes.adopt("T1", lane)
  Lanes.reconcile(["T1"], Dict.fromArray([("T1", "SOMETHING")]))
  T.equal(Lanes.owner("T1"), Some(lane))
})

// --- the screen -------------------------------------------------------------

laneTest("the screen stays up while another lane holds it", () => {
  // The interference this replaces: lane A summons a human for a captcha, lane
  // B finishes something unrelated and calls hideBrowser, and the window
  // disappears mid-solve.
  let first = Lanes.openLane()
  let second = Lanes.openLane()
  Lanes.claimScreen(first)
  Lanes.claimScreen(second)
  T.equal(Lanes.releaseScreen(second), false)
  T.equal(Lanes.releaseScreen(first), true)
})

laneTest("releasing a claim nobody holds is not an error", () => {
  T.equal(Lanes.releaseScreen(Lanes.openLane()), true)
})

laneTest("claiming twice still needs one release", () => {
  let lane = Lanes.openLane()
  Lanes.claimScreen(lane)
  Lanes.claimScreen(lane)
  T.equal(Lanes.releaseScreen(lane), true)
})

// --- closing ----------------------------------------------------------------

laneTest("closing reaches only this lane's tabs", () => {
  let mine = Lanes.openLane()
  let theirs = Lanes.openLane()
  Lanes.adopt("T1", mine)
  Lanes.adopt("T2", theirs)
  T.equal(Lanes.closeTabs(mine, ["T1", "T2"]), 1)
  T.equal(fake.closed, ["T1"])
  T.equal(Lanes.tabsOf(theirs), ["T2"])
})

laneTest("the last tab in the browser is never closed", () => {
  // Chrome exits when it loses its final tab, taking the daemon and the warm
  // session with it. The old `close_other_tabs` kept one back by being phrased
  // as "keep that one"; under lanes the survivor must belong to nobody in
  // particular, so the rule lives here instead, on the one path every close
  // goes through.
  fake.ids = ["ONLY"]
  let lane = Lanes.openLane()
  Lanes.adopt("ONLY", lane)
  T.equal(Lanes.closeTabs(lane, ["ONLY"]), 0)
  T.equal(fake.closed, [])
})

laneTest("a sweep collects an expired lane and its tabs", () => {
  let stale = Lanes.openLane(~ttlS=1)
  Lanes.adopt("T1", stale)
  Lanes.adopt("T2", Lanes.orphan)
  Lanes.adopt("T3", Lanes.orphan)
  let base = Math.floor(Date.now() /. 1000.0)
  Lanes.clock := (() => base +. 2.0)
  T.equal(Lanes.sweep(), [stale])
  T.equal(fake.closed, ["T1"])
  T.ok(notFound(() => Lanes.require(stale)))
})

laneTest("a sweep leaves orphan alone however old", () => {
  // A TTL on `orphan` would collect the tabs a human opened during a handoff,
  // which is the one thing ticket 018 exists to prevent.
  Lanes.adopt("T1", Lanes.orphan)
  let base = Math.floor(Date.now() /. 1000.0)
  Lanes.clock := (() => base +. 100000.0)
  T.equal(Lanes.sweep(), [])
  T.equal(fake.closed, [])
})

laneTest("an expired lane is refused rather than failing on a dangling row", () => {
  // The order bug: `require` before `sweep`.
  //
  // A lane that expired between calls is still a row, so checking first let it
  // through; the sweep then destroyed it underneath the call and the first
  // adopt hit a foreign key with nothing behind it -- a sqlite constraint
  // failure reaching the caller instead of LANE_NOT_FOUND. Sweeping first makes
  // the refusal the one the caller can act on.
  let lane = Lanes.openLane(~ttlS=1)
  let base = Math.floor(Date.now() /. 1000.0)
  Lanes.clock := (() => base +. 2.0)
  ignore(Lanes.sweep())
  T.ok(notFound(() => Lanes.require(lane)))
})

laneTest("counts reveal tabs piling up in a lane nobody is watching", () => {
  // The one number that reveals a lane you do not own -- a count, never a
  // listing, because a lane's tabs are nobody else's business.
  Lanes.adopt("T1", Lanes.openLane())
  Lanes.adopt("T2", Lanes.orphan)
  let (open_, orphaned) = Lanes.counts()
  T.equal(open_, 3)
  T.equal(orphaned, 1)
})
