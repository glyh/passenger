// Imperative shell: which lane owns which tab, and when a lane's time is up.
//
// Before this, tabs were one global pile with no owner: `close_tabs` took no
// argument and closed everything but a blank keeper, and `page(reuse=true)`
// handed back *any* `about:blank` it found -- so one caller closed the tab
// another was driving. Both are reachable with two agents and no exotic setup,
// because the MCP server is stdio: two sessions are two processes sharing one
// Chrome, and subagents inside one session share a single process *and*
// connection, so the transport cannot tell apart the parties most likely to
// collide.
//
// A lane is a scope of ownership with a lifetime. Tabs open inside it, only it
// can see or close them, and when its clock runs out they go. It is not `sink`:
// a sink is where a stream goes to die, and this is neither a destination nor
// final. See ticket 040.
//
// **Why sqlite.** Two server processes write this concurrently, so an
// in-process dictionary is not merely a restart hazard -- it is invisible to the
// other writer, which would leave each process believing it owned every tab.
//
// **Why not a BrowserContext per lane.** That is the elegant answer and it is
// disqualified: CDP browser contexts are incognito-like, separate cookie jar and
// storage, and the one warm logged-in profile is the entire point of the tool.
// Written down so it is not rediscovered as a good idea.
//
// **Chrome owns existence; this owns ownership.** A row here is meaningful only
// while Chrome still reports the target. Target ids are not reused across a
// restart, so the table is dropped when the daemon starts rather than carrying
// an epoch column: there is no reading of an old epoch that is ever useful.

@module("node:crypto") external randomBytes: int => 'buf = "randomBytes"
@send external toHex: ('buf, string) => string = "toString"
@module("node:fs") external mkdirSync: (string, {..}) => unit = "mkdirSync"
@module("node:path") external joinPath: (string, string) => string = "join"

/// A reserved lane. A row like any other -- same table, same sweep -- and
/// differs only in having a fixed, guessable id instead of a minted one.
///
/// It holds tabs nothing else can claim, overwhelmingly the ones a human opened
/// during a handoff, which have no opener to trace. Any caller may read and
/// close it, which makes it a junk drawer and it is documented as one.
let orphan = "orphan"

/// The other reserved lane: the human at the CLI.
///
/// `passenger show` puts the browser on screen for a person who is not an agent
/// and therefore has no lane of their own, and the screen is refcounted (see
/// "the screen" below) -- so without a row to hold, that look would be taken
/// away by the next agent's `hideBrowser`, which is precisely the interruption
/// ticket 040 built the refcount to stop. A fixed id rather than a minted one
/// because two processes have to name the same claim, and it never holds a tab:
/// unattributed targets go to `orphan`.
let human = "human"

let defaultTtlS = 1800

/// `orphan` keeps its tabs forever. A TTL there would auto-close a human's
/// half-finished login, which is the one thing ticket 018 exists to prevent.
let noTtl = 0

type lane = {id: string, ttlS: int, touchedAt: float}

let expiredAt = (lane, now) => lane.ttlS != noTtl && now -. lane.touchedAt >= Int.toFloat(lane.ttlS)

/// The three questions this module asks Chrome.
///
/// A record of functions rather than an interface, and the seam is at the
/// *process* boundary rather than inside any rule here: what is swapped out is
/// a browser on the other end of an HTTP endpoint, which is exactly the kind of
/// thing a unit test has no business starting. Nothing about a lane's own logic
/// is reachable through it, which is the line tickets 001 and 034 drew.
///
/// Every question is async here, where the C# interface answered synchronously.
/// That side reached the same endpoints through `.GetAwaiter().GetResult()`;
/// JavaScript has no such move, so the promise travels and the four rules below
/// that ask Chrome anything are async with it. The rules themselves are
/// unchanged -- what could not be blocked on is a property of the runtime, not
/// of what a lane means.
type chromeTabs = {
  liveTabs: unit => promise<array<string>>,
  close: string => promise<bool>,
  openers: unit => promise<Dict.t<string>>,
}

/// The real Chrome, over the CDP HTTP endpoint and the browser's own socket.
let liveChrome: chromeTabs = {
  liveTabs: async () => (await Targets.pages())->Array.map(t => t.id),
  close: Targets.close,
  openers: () => Targets.openers(),
}

let chrome = ref(liveChrome)

let dbFile = () => joinPath(Config.stateDir.contents, "lanes.db")

let schema = `CREATE TABLE IF NOT EXISTS lanes (
  id         TEXT PRIMARY KEY,
  ttl_s      INTEGER NOT NULL,
  touched_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS tabs (
  tab  TEXT PRIMARY KEY,
  lane TEXT NOT NULL REFERENCES lanes(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS screen_claims (
  lane TEXT PRIMARY KEY REFERENCES lanes(id) ON DELETE CASCADE
);`

// Wall clock, not monotonic: monotonic does not cross processes, and two
// processes are exactly who reads this.
//
// Behind a ref, which is the second seam in this module and the only one that
// is not a process boundary. The C# suite bought the same coverage with
// `Thread.Sleep(1100)` twice; a clock a test can move is 2.2 seconds cheaper
// per run and does not turn a slow machine into a flake.
let clock = ref(() => Math.floor(Date.now() /. 1000.0))
let now = () => clock.contents()

/// One connection, with the schema and the reserved lanes guaranteed.
///
/// WAL because the other writer is another process, `foreign_keys` because the
/// cascade from `lanes` is what keeps a destroyed lane from leaving rows that
/// name it, and `busy_timeout` because sqlite's default of zero turns the
/// second writer's contention into an immediate "database is locked" rather
/// than a wait. Two processes writing this is the normal case, not the exotic
/// one.
let open_ = () => {
  mkdirSync(Config.stateDir.contents, {"recursive": true})
  let db = Sqlite.database(dbFile())
  db->Sqlite.exec("PRAGMA journal_mode=WAL")
  db->Sqlite.exec("PRAGMA foreign_keys=ON")
  db->Sqlite.exec("PRAGMA busy_timeout=10000")
  db->Sqlite.exec(schema)
  let reserve =
    db->Sqlite.prepare("INSERT OR IGNORE INTO lanes (id, ttl_s, touched_at) VALUES ($id, $ttl, $at)")
  [orphan, human]->Array.forEach(id => reserve->Sqlite.run({"id": id, "ttl": noTtl, "at": now()}))
  db
}

let withDb = f => {
  let db = open_()
  let out = try f(db) catch {
  | e =>
    db->Sqlite.close
    throw(e)
  }
  db->Sqlite.close
  out
}

/// Forget everything. Called when a fresh Chrome starts.
///
/// Not a migration and not a repair: every row here names a CDP target id from
/// a browser that is gone, and those ids are never handed out again.
let reset = () =>
  withDb(db =>
    db->Sqlite.exec(
      "DROP TABLE IF EXISTS screen_claims; DROP TABLE IF EXISTS tabs; DROP TABLE IF EXISTS lanes;",
    )
  )

/// Mint a lane and return its id.
///
/// Server-side rather than caller-named. A caller-chosen name saves one round
/// trip and collides the moment two subagents of one session both pick
/// "scratch", which is the failure this whole mechanism exists to remove.
let openLane = (~ttlS=defaultTtlS) => {
  let id = randomBytes(8)->toHex("hex")
  withDb(db =>
    db
    ->Sqlite.prepare("INSERT OR IGNORE INTO lanes (id, ttl_s, touched_at) VALUES ($id, $ttl, $at)")
    ->Sqlite.run({"id": id, "ttl": ttlS, "at": now()})
  )
  id
}

type laneRow = {id: string, ttl_s: int, touched_at: float}

/// The lane, or LANE_NOT_FOUND. Every lane-taking call starts here.
let require = id =>
  withDb(db => {
    let rows: array<laneRow> =
      db
      ->Sqlite.prepare("SELECT id, ttl_s, touched_at FROM lanes WHERE id = $id")
      ->Sqlite.all({"id": id})
    switch rows->Array.get(0) {
    | Some(r) => {id: r.id, ttlS: r.ttl_s, touchedAt: r.touched_at}
    | None =>
      throw(Errors.laneNotFound(id))
    }
  })

/// Restart the lane's clock.
///
/// Called on entry *and* on return of every call naming the lane, because a
/// `script` with a 600s budget must not expire underneath itself.
let touch = id =>
  withDb(db =>
    db
    ->Sqlite.prepare("UPDATE lanes SET touched_at = $at WHERE id = $id")
    ->Sqlite.run({"at": now(), "id": id})
  )

/// Change how long this lane may sit quiet, and restart its clock.
let setTtl = (id, seconds) => {
  ignore(require(id))
  withDb(db =>
    db
    ->Sqlite.prepare("UPDATE lanes SET ttl_s = $ttl, touched_at = $at WHERE id = $id")
    ->Sqlite.run({"ttl": seconds > 0 ? seconds : 0, "at": now(), "id": id})
  )
}

/// Record that this tab belongs to this lane, moving it if it did not.
let adopt = (tab, lane) =>
  withDb(db =>
    db
    ->Sqlite.prepare(
      "INSERT INTO tabs (tab, lane) VALUES ($tab, $lane) ON CONFLICT(tab) DO UPDATE SET lane = excluded.lane",
    )
    ->Sqlite.run({"tab": tab, "lane": lane})
  )

type tabRow = {tab: string, lane: string}

let owner = tab =>
  withDb(db => {
    let rows: array<tabRow> =
      db->Sqlite.prepare("SELECT tab, lane FROM tabs WHERE tab = $tab")->Sqlite.all({"tab": tab})
    rows->Array.get(0)->Option.map(r => r.lane)
  })

let tabsOf = lane =>
  withDb(db => {
    let rows: array<tabRow> =
      db->Sqlite.prepare("SELECT tab, lane FROM tabs WHERE lane = $lane")->Sqlite.all({"lane": lane})
    rows->Array.map(r => r.tab)
  })

/// Drop rows for tabs that are gone. Closing is somebody else's job.
let forget = tabs =>
  withDb(db => {
    let stmt = db->Sqlite.prepare("DELETE FROM tabs WHERE tab = $tab")
    tabs->Array.forEach(tab => stmt->Sqlite.run({"tab": tab}))
  })

/// Remove the lane. Its tab and claim rows cascade.
///
/// The caller closes the tabs first. A lane removed while its tabs are still
/// open would leave them with no owner, no clock and no caller who can see
/// them -- permanently unreachable, which is worse than the pile this replaces.
let destroy = lane =>
  withDb(db =>
    if lane == orphan {
      // The reserved lane is emptied, never removed: the next call would
      // recreate it anyway, and `destroyLane('orphan')` reading as success
      // while the lane came straight back is a lie.
      db->Sqlite.prepare("DELETE FROM tabs WHERE lane = $lane")->Sqlite.run({"lane": lane})
    } else {
      db->Sqlite.prepare("DELETE FROM lanes WHERE id = $id")->Sqlite.run({"id": lane})
    }
  )

type idRow = {id: string}

let expired = (~at=?) => {
  let at = at->Option.getOr(now())
  withDb(db => {
    let rows: array<idRow> =
      db
      ->Sqlite.prepare("SELECT id FROM lanes WHERE ttl_s != 0 AND $at - touched_at >= ttl_s")
      ->Sqlite.all({"at": at})
    rows->Array.map(r => r.id)
  })
}

type touchedRow = {touched: Nullable.t<float>}

/// The freshest touch in the registry: the last moment anyone, in any
/// process, did anything through this side. This is the reaper's whole
/// measurement of idleness (ticket 076) -- `touched_at` is written on entry
/// *and* return of every lane-naming call, so a call in flight reads as use
/// at both ends, and the wall clock it is kept under is the one fact here
/// that crosses processes, which is what disqualifies last-CDP-activity:
/// the attach lives in one process for one call, so a CDP-derived clock
/// cannot see the lane next door.
///
/// Never empty in practice -- `open_` reserves two rows at creation and
/// `Browser.start` drops the tables -- but a missing answer reads as "just
/// used", which is the direction that cannot reap anything.
let newestTouch = () =>
  withDb(db => {
    let rows: array<touchedRow> =
      db->Sqlite.prepare("SELECT MAX(touched_at) AS touched FROM lanes")->Sqlite.allBare
    rows->Array.get(0)->Option.flatMap(r => r.touched->Nullable.toOption)->Option.getOr(now())
  })

// --- the screen -------------------------------------------------------------
//
// Lanes divide tabs. They do not divide the compositor, the VNC server or the
// viewer window, and `hideBrowser` used to take no arguments and dismiss the
// presenter globally -- so lane A summoning a human for a captcha and lane B
// calling `hideBrowser` thirty seconds later took the window away mid-solve.
// That is one lane interrupting another, which is the thing lanes are for.
//
// So the screen is refcounted: a claim per lane, and the viewer comes down when
// the last one goes.

let claimScreen = lane =>
  withDb(db =>
    db
    ->Sqlite.prepare("INSERT OR IGNORE INTO screen_claims (lane) VALUES ($lane)")
    ->Sqlite.run({"lane": lane})
  )

type claimRow = {lane: string}

let screenClaims = () =>
  withDb(db => {
    let rows: array<claimRow> =
      db->Sqlite.prepare("SELECT lane FROM screen_claims")->Sqlite.allBare
    rows->Array.map(r => r.lane)
  })

/// Drop this lane's claim. True when nobody is left holding the screen.
let releaseScreen = lane => {
  withDb(db =>
    db->Sqlite.prepare("DELETE FROM screen_claims WHERE lane = $lane")->Sqlite.run({"lane": lane})
  )
  screenClaims()->Array.length == 0
}

/// Drop every claim, whoever holds it. True always -- nobody is left.
///
/// The blunt one, and deliberately not reachable from a tool: an agent that
/// takes the window away from another lane's human mid-captcha is the failure
/// the refcount exists to prevent, so this is the CLI's alone, behind `--force`,
/// on the same rule that keeps `stop` off the tool list (ticket 057).
let releaseAllScreens = () => {
  withDb(db => db->Sqlite.exec("DELETE FROM screen_claims"))
  true
}

/// Lanes that would lose work if Chrome went away now, with how many tabs each
/// holds -- what `stop` refuses on (ticket 057) -- or `None` when the question
/// could not be asked.
///
/// Live tabs, not rows: a row for a tab Chrome no longer has is not work, and
/// the sweep that would drop it may not have run. Reserved lanes are excluded
/// because Chrome is launched with `about:blank`, which lands in `orphan` on the
/// first reconcile -- counting it would mean a refusal that never lifts.
///
/// The two callers want opposite readings of the same failure, which is why
/// the answer and the failure are separable at all. `occupied` below is
/// `stop`'s: a wedged browser is the case `stop` exists for, and a check that
/// cannot complete must not be what stands in the way of a human holding
/// `--force`, so the failure reads as empty. The reaper wants the other
/// polarity (ticket 076): a clock that cannot *see* that the lanes are empty
/// does not know the browser is idle, and must skip the round rather than
/// kill what it could not inspect -- so it asks here, where `None` means
/// unknown, and unknown never fires.
let occupiedKnown = async () =>
  switch await chrome.contents.liveTabs() {
  | live =>
    let counts = Dict.make()
    withDb(db => {
      let rows: array<tabRow> =
        db
        ->Sqlite.prepare("SELECT tab, lane FROM tabs WHERE lane != $orphan")
        ->Sqlite.all({"orphan": orphan})
      rows->Array.forEach(r =>
        if live->Array.includes(r.tab) {
          counts->Dict.set(r.lane, counts->Dict.get(r.lane)->Option.getOr(0) + 1)
        }
      )
    })
    Some(
      counts
      ->Dict.toArray
      ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b)),
    )
  | exception _ => None
  }

/// The same question, answering `stop`'s reading of it: unknown is empty, so
/// a wedged browser never stands between a human and `--force`.
let occupied = async () => (await occupiedKnown())->Option.getOr([])

/// Make the table agree with what Chrome actually holds.
///
/// Two directions. Rows for tabs that are gone are dropped -- a stale row would
/// make `listTabs` promise a tab that closed. And targets with no row are
/// attributed: to the lane of whichever tab opened them when Chrome says one
/// did, otherwise to `orphan`.
///
/// Adoption by opener is what keeps `window.open` and `target="_blank"` from
/// leaking. Such a target has no row, so nobody can see it, nobody can close it,
/// and the sweep never reaches it -- the sweep collects lanes, not tabs.
let reconcile = (live: array<string>, openedBy: Dict.t<string>) =>
  withDb(db => {
    let known = Dict.make()
    let rows: array<tabRow> = db->Sqlite.prepare("SELECT tab, lane FROM tabs")->Sqlite.allBare
    rows->Array.forEach(r => known->Dict.set(r.tab, r.lane))

    let drop = db->Sqlite.prepare("DELETE FROM tabs WHERE tab = $tab")
    known
    ->Dict.keysToArray
    ->Array.forEach(tab =>
      if !(live->Array.includes(tab)) {
        drop->Sqlite.run({"tab": tab})
        known->Dict.delete(tab)
      }
    )

    let insert = db->Sqlite.prepare("INSERT INTO tabs (tab, lane) VALUES ($tab, $lane)")
    live->Array.forEach(tab =>
      switch known->Dict.get(tab) {
      | Some(_) => ()
      | None =>
        // An opener whose own row is missing means a chain of popups seen out of
        // order; `orphan` is the honest answer rather than a guess.
        let opener = openedBy->Dict.get(tab)->Option.getOr("")
        let lane = known->Dict.get(opener)->Option.getOr(orphan)
        insert->Sqlite.run({"tab": tab, "lane": lane})
        known->Dict.set(tab, lane)
      }
    )
  })

/// Close these tabs of this lane, and forget them. Returns how many went.
///
/// **The last tab is never closed.** Chrome exits when it loses its final tab,
/// which would take the daemon and the warm session with it. The old
/// `close_other_tabs` kept one back by being phrased as "keep that one"; under
/// lanes the survivor must belong to nobody in particular, so the rule becomes
/// an invariant here instead: whatever is asked for, one page stays. It lands in
/// `orphan` on the next reconcile, which is the correct home for a tab that
/// exists only so Chrome keeps running.
let closeTabs = async (lane, tabs) => {
  let mine = tabsOf(lane)
  let doomed = tabs->Array.filter(t => mine->Array.includes(t))
  switch await chrome.contents.liveTabs() {
  | live =>
    let doomed = if doomed->Array.length >= live->Array.length {
      // Would empty the browser. Hold one back rather than closing it and
      // racing to open a replacement before Chrome notices.
      doomed->Array.slice(~start=0, ~end=live->Array.length > 1 ? live->Array.length - 1 : 0)
    } else {
      doomed
    }
    let closed = ref(0)
    for i in 0 to doomed->Array.length - 1 {
      let tab = doomed->Array.getUnsafe(i)
      if await chrome.contents.close(tab) {
        closed := closed.contents + 1
      }
      forget([tab])
    }
    closed.contents
  | exception _ => 0
  }
}

/// Reconcile, then collect every lane whose clock ran out. Returns which.
///
/// Opportunistic: run at the top of any call that touches the registry, so there
/// is no background thread and nothing to keep alive.
let sweep = async () =>
  switch await chrome.contents.liveTabs() {
  | live =>
    reconcile(live, await chrome.contents.openers())
    let dead = expired()
    for i in 0 to dead->Array.length - 1 {
      let lane = dead->Array.getUnsafe(i)
      let _ = await closeTabs(lane, tabsOf(lane))
      destroy(lane)
    }
    dead
  | exception _ => [] // no daemon, or it is not answering; nothing to reconcile
  }

/// Total pages Chrome holds, and how many are in `orphan`.
///
/// The one number that reveals a lane you do not own. A caller sees only its own
/// tabs, so without this there is no view anywhere in the tool that shows tabs
/// piling up. A count is a measurement; ids and owners would be a listing, which
/// is the side of the line agents stay off.
let counts = async () =>
  switch await chrome.contents.liveTabs() {
  | live => (live->Array.length, tabsOf(orphan)->Array.filter(t => live->Array.includes(t))->Array.length)
  | exception _ => (0, 0)
  }

/// Which lanes these tabs belong to, for saying whose work was touched.
///
/// `Browser.LanesOf` on the C# side. It is a question about lanes and it reads
/// the registry, so here it lives with the registry -- which also keeps
/// `Session`, its only caller, from having to depend on `Browser` at all.
let lanesOf = (pages: array<Models.target>) => {
  let owners = []
  pages->Array.forEach(p => {
    let who = switch owner(p.id) {
    | Some(lane) => lane
    | None => orphan
    }
    if !(owners->Array.includes(who)) {
      owners->Array.push(who)
    }
  })
  owners->Array.sort(String.compare)
  owners->Array.length > 0 ? "lane " ++ owners->Array.join(", ") : "no lane"
}
