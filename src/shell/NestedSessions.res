// Imperative shell: which sway/wayvnc/viewer processes are *ours*.
//
// `NestedSessions`, not `Sessions`, and the extra word is doing work: `Session`
// -- singular, next door -- is the Playwright attach, and the two have nothing
// to do with each other. They were one letter apart for a while, which is how
// the C# name `NestedSessions.cs` earned itself back.
//
// Every process this tool starts is nested one inside another -- sway holds
// wayvnc and Chrome, and a viewer connects to that wayvnc from outside. Nothing
// in the process table says which of them belong together, so this module keeps
// the one record that does.
//
// Without it the correlation was guessed by name, and both directions of the
// guess were wrong. A second cage session inherited the first one's hardcoded
// VNC port, so its wayvnc lost the bind and died while the *stale* one kept
// serving an empty compositor -- a viewer that connects and shows black. In the
// other direction `pkill -x cage` and a `pkill -x` on the viewer's binary
// reached every such process on the machine, so this tool tore down sessions and
// remote desktops that were never its own.
//
// The record is written by the session script itself, from inside the session,
// because that is the only place that can observe what actually came up: the
// display it got, and the pids of the processes it really started.

/// One live nested session, as reported from inside it.
type session = {
  compositorPid: int,
  chromePid: int,
  vncPid: int,
  vncHost: string,
  vncPort: int,
  ctlSocket: string,
  waylandDisplay: string,
}

let sessionFile = () => Fs.join(Config.stateDir.contents, "session.env")
let viewerFile = () => Fs.join(Config.stateDir.contents, "viewer.pid")

let portScan = 64
let exitPolls = 20
let killPolls = 20
let pollIntervalMs = 100

/// Is this pid a running process?
///
/// A zombie does not count. Chrome dying inside the session leaves an unreaped
/// child whose pid still answers signal 0, so a liveness check built on kill(2)
/// alone reports a dead session as live -- which is the state that had a viewer
/// showing a black screen with everything claiming to be fine.
let readProcState = pid =>
  switch Fs.readFileSync(`/proc/${pid->Int.toString}/stat`, "utf8") {
  | stat =>
    // Field 3 is the state code, after the comm field, which may itself contain
    // spaces or brackets -- so split from the last ')' rather than tokenising
    // the whole line.
    switch stat->String.lastIndexOf(")") {
    | -1 => false
    | close =>
      switch stat
      ->String.slice(~start=close + 1, ~end=stat->String.length)
      ->String.split(" ")
      ->Array.filter(f => f != "")
      ->Array.get(0) {
      | Some(state) => state != "Z"
      | None => false
      }
    }
  | exception JsExn(e) =>
    // Exists, owned by someone else. Every other failure -- gone, or no /proc at
    // all -- is a pid this tool cannot claim is running.
    Fs.errorCode(e)->Option.getOr("") == "EACCES"
  }

/// How liveness is decided. Replaced only by the suite, and only for the one
/// case that cannot be produced honestly: nothing in userspace survives SIGKILL,
/// so a pid that does -- one in uninterruptible sleep, or one that is not ours --
/// has to be stood in for. The Python tests monkeypatched the same function for
/// the same reason.
let alive = ref(readProcState)
let isAlive = pid => alive.contents(pid)

/// Chrome is the session: the compositor exists only to hold it.
///
/// Keyed on Chrome rather than on the compositor because a compositor outliving
/// a dead Chrome is exactly the stale state this record has to detect -- that is
/// the shape the black screen came in. Under cage that state arrived only by
/// accident, since cage exited with its child; sway does not, which is why the
/// session script kills it deliberately and why this check matters more than it
/// did.
let sessionAlive = session => isAlive(session.chromePid)

/// Pure: the `key=value` lines of a session record.
let parseRecord = text => {
  let pairs = Dict.make()
  text
  ->String.split("\n")
  ->Array.forEach(line =>
    switch line->String.indexOf("=") {
    | split if split > 0 =>
      pairs->Dict.set(
        line->String.slice(~start=0, ~end=split),
        line
        ->String.slice(~start=split + 1, ~end=line->String.length)
        ->String.replaceRegExp(%re("/\r$/"), ""),
      )
    | _ => ()
    }
  )
  pairs
}

/// The compositor's pid, under either name.
///
/// `cage_pid` was the key until ticket 063 swapped the compositor for sway. A
/// record on disk outlives the upgrade that renamed it, and the session it names
/// is a real cage still holding the port and the profile -- so the old key is
/// still read, purely so that session can be torn down rather than orphaned.
/// Nothing writes it any more.
let compositorPidOf = fields =>
  switch fields->Dict.get("compositor_pid") {
  | Some(pid) => Some(pid)
  | None => fields->Dict.get("cage_pid")
  }

/// Pure: a record's fields as a session, or `None` if it does not describe one.
///
/// A malformed or half-written record is treated as absent rather than raising:
/// the caller's next move is to start a fresh session either way.
let sessionOf = fields => {
  let int = key => fields->Dict.get(key)->Option.flatMap(v => Int.fromString(v))
  switch (
    compositorPidOf(fields)->Option.flatMap(v => Int.fromString(v)),
    int("chrome_pid"),
    int("vnc_pid"),
    int("vnc_port"),
    fields->Dict.get("vnc_host"),
    fields->Dict.get("ctl_socket"),
    fields->Dict.get("wayland_display"),
  ) {
  | (
      Some(compositorPid),
      Some(chromePid),
      Some(vncPid),
      Some(vncPort),
      Some(vncHost),
      Some(ctlSocket),
      Some(waylandDisplay),
    ) if vncPort >= 1 && vncPort <= 65535 =>
    Some({compositorPid, chromePid, vncPid, vncHost, vncPort, ctlSocket, waylandDisplay})
  | _ => None
  }
}

/// The recorded session, or `None` if there is no readable one.
let current = () => Fs.readText(sessionFile())->Option.flatMap(t => sessionOf(parseRecord(t)))

let live = () => current()->Option.filter(sessionAlive)

// --- ports ------------------------------------------------------------------

/// Is something listening there?
///
/// A connect probe, the same act the C# side performed with a TcpClient. Node's
/// sockets are asynchronous only, so this is the second place the runtime turns
/// a synchronous question into a promise -- and unlike `Lanes.chromeTabs` it
/// stops here, because the two callers (`freePort`, `Webserve.listening`) are
/// both already async.
type socket
@module("node:net") external connect: ({..}, unit => unit) => socket = "createConnection"
@send external onSocketError: (socket, string, 'a => unit) => socket = "on"
@send external destroySocket: socket => unit = "destroy"
@send external setSocketTimeout: (socket, int, unit => unit) => socket = "setTimeout"

let isListening = (host, port, ~timeoutMs=300) =>
  Promise.make((resolve, _reject) => {
    let settled = ref(false)
    let finish = answer =>
      if !settled.contents {
        settled := true
        resolve(answer)
      }

    let socket = connect({"host": host, "port": port}, () => finish(true))
    socket->onSocketError("error", _ => finish(false))->ignore
    socket->setSocketTimeout(timeoutMs, () => finish(false))->ignore
    // Whichever way it went, the probe is done with the socket. Left open, a
    // successful connect would sit in the other end's accept queue.
    let _ = Timers.setTimeout(() =>
      switch destroySocket(socket) {
      | () => ()
      | exception _ => ()
      }
    , timeoutMs + 50)
  })

/// First free port at or above the configured one.
///
/// Scanned rather than fixed so a second session -- or anyone else's wayvnc --
/// cannot silently take the port this one is about to advertise.
let freePort = async () => {
  let base = Config.vncPort.contents
  let found = ref(None)
  for offset in 0 to portScan - 1 {
    if found.contents->Option.isNone {
      let port = base + offset
      if !(await isListening(Config.vncHost.contents, port)) {
        found := Some(port)
      }
    }
  }
  found.contents->Option.getOr(base)
}

/// The socket inode listening on a port, out of a /proc/net/tcp table.
///
/// Pure, and separated from the file reading so the column arithmetic is
/// testable without binding anything: the table is hex, the state code `0A` is
/// LISTEN, and the port is the tail of the local address rather than a field of
/// its own.
let listeningInode = (lines, port) => {
  let found = ref(None)
  lines->Array.forEach(line =>
    if found.contents->Option.isNone {
      let fields = line->String.split(" ")->Array.filter(f => f != "")
      let state = fields->Array.get(3)->Option.getOr("")
      if fields->Array.length >= 10 && state == "0A" {
        let local = fields->Array.getUnsafe(1)
        switch local->String.lastIndexOf(":") {
        | -1 => ()
        | colon =>
          let listening = Int.fromString(
            local->String.slice(~start=colon + 1, ~end=local->String.length),
            ~radix=16,
          )
          switch listening {
          | Some(on) if on == port =>
            found := fields->Array.get(9)->Option.flatMap(v => Float.fromString(v))
          | _ => ()
          }
        }
      }
    }
  )
  found.contents
}

let tcpTables = ["/proc/net/tcp", "/proc/net/tcp6"]

let pids = () =>
  switch Fs.readdirSync("/proc") {
  | entries => entries->Array.filterMap(e => Int.fromString(e))
  | exception _ => []
  }

/// The process holding one socket inode, by the fd symlinks that name it.
///
/// O(processes x fds), which is affordable only because this runs once, on the
/// way to refusing a port -- never on a hot path.
let pidHoldingSocket = inode => {
  let target = `socket:[${inode->Float.toString}]`
  let found = ref(None)
  pids()->Array.forEach(pid =>
    if found.contents->Option.isNone {
      let dir = `/proc/${pid->Int.toString}/fd`
      switch Fs.readdirSync(dir) {
      | fds =>
        fds->Array.forEach(fd =>
          if found.contents->Option.isNone {
            switch Fs.readlinkSync(Fs.join(dir, fd)) {
            | link if link == target => found := Some(pid)
            | _ => ()
            // The fd closed between listing and reading. Keep looking.
            | exception _ => ()
            }
          }
        )
      // Someone else's process, or one that just exited.
      | exception _ => ()
      }
    }
  )
  found.contents
}

/// One process's command line, spaces where the NULs were.
///
/// For showing a human which process to stop, so it is decoded here -- unlike
/// `pidsRunning`, which matches on the raw bytes precisely to avoid decoding one.
let commandOf = pid =>
  switch Fs.readFileSync(`/proc/${pid->Int.toString}/cmdline`, "latin1") {
  | raw =>
    let text = raw->String.replaceAllRegExp(%re("/\0/g"), " ")->String.trim
    text == "" ? None : Some(text)
  | exception _ => None
  }

/// Who is listening on a local port: pid and command line, when they can be
/// found.
///
/// A socket probe answers "is something there", and that stood in for "is *this*
/// there" until ticket 058 found this tool's own Python predecessor still holding
/// the viewer port from before the project was renamed. Refusing a port is only
/// useful advice if the refusal names the process to stop, and /proc is the only
/// thing that knows which one that is.
///
/// Best effort throughout: a socket held by another user has no fd list this
/// process may read, so the answer is `None` and the caller says less rather than
/// nothing.
let listenerOn = port => {
  let found = ref(None)
  tcpTables->Array.forEach(table =>
    if found.contents->Option.isNone {
      switch Fs.readText(table) {
      | Some(text) =>
        switch listeningInode(text->String.split("\n"), port) {
        | Some(inode) =>
          found :=
            pidHoldingSocket(inode)->Option.map(pid => (
              pid,
              commandOf(pid)->Option.getOr("unknown command"),
            ))
        | None => ()
        }
      // No /proc/net at all, or not Linux.
      | None => ()
      }
    }
  )
  found.contents
}

/// Pids whose command line contains `fragment`.
///
/// Reads /proc directly rather than shelling out to pgrep: the match is the
/// security-relevant part of stopping the right processes, and doing it here
/// makes it an ordinary function -- inspectable, and testable without spawning
/// anything.
///
/// Matched on the raw bytes because /proc/pid/cmdline separates its arguments
/// with NUL, and decoding it would either lose those boundaries or fail on a
/// command line that is not valid UTF-8. `latin1` is the decoding that does
/// neither: it is a byte-for-byte mapping, so a substring search over it is a
/// substring search over the bytes.
let pidsRunning = fragment =>
  pids()->Array.filter(pid =>
    switch Fs.readFileSync(`/proc/${pid->Int.toString}/cmdline`, "latin1") {
    | cmdline => cmdline->String.includes(fragment)
    // Exited between listing and reading.
    | exception _ => false
    }
  )

/// Per-port control socket.
///
/// wayvnc refuses to start when another instance holds the default one, which is
/// how the second session lost its VNC server without anything reporting it.
let ctlSocket = port => Fs.join(Config.stateDir.contents, `wayvnc-${port->Int.toString}.sock`)

// --- teardown ---------------------------------------------------------------

/// Drop the per-port state, now that nothing is left to own it.
let forget = session => {
  Fs.delete(session.ctlSocket)
  Fs.delete(sessionFile())
}

/// Poll until every pid is gone, and report those that are not.
let waitForExit = async (pids, polls) => {
  let _ = await Poll.until(~times=polls, ~everyMs=pollIntervalMs, async () =>
    !(pids->Array.some(isAlive))
  )
  pids->Array.filter(isAlive)
}

/// Stop a session's processes. Returns a note if any of them survived.
///
/// Waited on rather than fired and forgotten: SIGTERM is asynchronous, so a
/// session started immediately afterwards would still find the old listener
/// holding the port and quietly claim a different one, drifting upward on every
/// restart.
///
/// The wait used to end in a shrug -- the budget ran out and the record was
/// unlinked regardless, which is that same drift with the record that names the
/// surviving pid deleted, so `reapStale` could not clean up after it either.
/// SIGTERM is now escalated, and the record is kept in the one case where even
/// that fails, because an unowned listener is the worse half of the bug.
let stopAll = async session => {
  // Deduplicated so a record that names one process twice cannot report it twice
  // in the note.
  let pids = [session.vncPid, session.compositorPid]->Array.reduce([], (kept, pid) =>
    kept->Array.includes(pid) ? kept : kept->Array.concat([pid])
  )
  pids->Array.forEach(pid => Posix.kill(pid, Posix.sigterm))

  let survivors = await waitForExit(pids, exitPolls)
  if survivors->Array.length == 0 {
    forget(session)
    None
  } else {
    survivors->Array.forEach(pid => Posix.kill(pid, Posix.sigkill))
    let stubborn = await waitForExit(survivors, killPolls)
    if stubborn->Array.length == 0 {
      forget(session)
      None
    } else {
      // Deliberately keeps the record, and with it the control socket the
      // survivor may still be serving: it is the only thing that ties this port
      // to a session anyone can name, and `reapStale` reads it on the next run.
      Some(
        `pid ${stubborn->Array.map(p => p->Int.toString)->Array.join(", ")} survived SIGKILL; ` ++
        `:${session.vncPort->Int.toString} is still held, session record kept`,
      )
    }
  }
}

/// Tear down a recorded session whose Chrome is gone. Returns what it killed.
///
/// Called before starting a new one so the dead session cannot keep holding the
/// VNC port that the new session needs to advertise.
let reapStale = async () =>
  switch current() {
  | Some(session) if !sessionAlive(session) =>
    let survived = await stopAll(session)
    let reaped = `reaped stale session on :${session.vncPort->Int.toString}`
    switch survived {
    | None => Some(reaped)
    | Some(note) => Some(`${reaped}; ${note}`)
    }
  | _ => None
  }

/// Stop only the processes this record names. Returns what would not go.
let teardown = async () =>
  switch current() {
  | Some(session) => await stopAll(session)
  | None => None
  }

/// SIGTERM one process, tolerating its having already gone.
let terminate = pid => Posix.kill(pid, Posix.sigterm)

// --- the viewer -------------------------------------------------------------

let recordViewer = pid => {
  Fs.mkdirp(Config.stateDir.contents)
  Fs.writeFileSync(viewerFile(), pid->Int.toString)
}

/// The viewer this tool spawned, if it is still running.
///
/// Checked by pid and not by name so that a VNC client the user opened for
/// something else is never mistaken for ours -- in either direction.
let viewerPid = () =>
  Fs.readText(viewerFile())
  ->Option.flatMap(t => Int.fromString(t->String.trim))
  ->Option.filter(isAlive)

let clearViewer = () => Fs.delete(viewerFile())

// --- the page server ---------------------------------------------------------

let viewerServerFile = () => Fs.join(Config.stateDir.contents, "viewer-server.pid")

/// The viewer page server's pid, recorded when it is spawned.
///
/// `Webserve.ensure` used to drop this pid on the floor, and nothing anywhere
/// killed the process: a detached re-exec serving two static files outlived
/// `passenger stop` until logout (ticket 076). Recorded now, so the shared
/// teardown can name it -- by pid, not by a sweep over command lines, because
/// a second checkout of this tool shares the private flag and not the state
/// dir, and kill-by-name is the exact scar `Present.dismiss`'s comment is
/// about.
let recordViewerServer = pid => {
  Fs.mkdirp(Config.stateDir.contents)
  Fs.writeFileSync(viewerServerFile(), pid->Int.toString)
}

let viewerServerPid = () =>
  Fs.readText(viewerServerFile())
  ->Option.flatMap(t => Int.fromString(t->String.trim))
  ->Option.filter(isAlive)

let clearViewerServer = () => Fs.delete(viewerServerFile())

// --- the reaper --------------------------------------------------------------

let watchdogFile = () => Fs.join(Config.stateDir.contents, "watchdog.pid")

/// The idle reaper's pid, recorded when `Browser.start` summons it.
///
/// The record is what keeps starts from stacking reapers -- a Chrome already
/// running when the next client connects still needs one watching it, but not
/// two -- and what lets a caller tell a live reaper from a dead one, the same
/// question `viewerPid` answers for the viewer window.
let recordWatchdog = pid => {
  Fs.mkdirp(Config.stateDir.contents)
  Fs.writeFileSync(watchdogFile(), pid->Int.toString)
}

let watchdogPid = () =>
  Fs.readText(watchdogFile())
  ->Option.flatMap(t => Int.fromString(t->String.trim))
  ->Option.filter(isAlive)

let clearWatchdog = () => Fs.delete(watchdogFile())
