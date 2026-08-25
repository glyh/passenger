// The session record and its process predicates.
//
// The oracle is `tests/Passenger.Tests/SessionTests.cs`, all fourteen cases.
// Every one of them is a scar. A stale `wayvnc` serving a dead compositor while
// every status read healthy -- a black screen with nothing reporting a fault --
// and two bugs surfaced by hand during that work: a liveness check counting
// zombies as alive, and the VNC port drifting upward on every restart because
// SIGTERM is asynchronous. Neither would have been caught by review, and nothing
// but this stops either returning.
//
// These run against real processes rather than fixture text. `readProcState`
// reads `/proc/<pid>/stat`, so the thing under test is the actual read and the
// actual parse, not a seam holding a string somebody typed. `sh` and `sleep` are
// not sway, wayvnc and Chrome: nothing here starts the real stack.
//
// State is redirected below, which is load-bearing rather than tidy: without it
// a test that called `teardown` would SIGTERM the pids in the developer's *real*
// session record and unlink it, killing a live browser to run a unit test. The
// VNC port is pinned for a subtler reason -- `freePort` scans upward from the
// configured one, so a test asserting it returns that port would pass in a
// sandbox and fail on the machine of anyone with a live session holding 5900.

@module("node:fs") external mkdtempSync: string => string = "mkdtempSync"
@module("node:os") external tmpdir: unit => string = "tmpdir"

Config.stateDir := mkdtempSync(tmpdir() ++ "/passenger-sessions-")

// --- children ---------------------------------------------------------------

type child
type server
@module("node:child_process") external spawn: (string, array<string>, {..}) => child = "spawn"
@get external stdout: child => 'stream = "stdout"
@get external childPid: child => int = "pid"
@send external killChild: (child, string) => unit = "kill"
@send external onData: ('stream, string, string => unit) => unit = "on"
@send external setEncoding: ('stream, string) => unit = "setEncoding"

@module("node:net") external createServer: unit => server = "createServer"
@send external listen: (server, int, string, unit => unit) => unit = "listen"
@send external closeServer: (server, unit => unit) => unit = "close"
@send external address: server => {"port": int} = "address"

/// A port nothing holds right now, as a base for the scan tests.
///
/// `freePort` scans upward from the configured one, so a test asserting it
/// returns that port would pass in a sandbox -- private network namespace, 5900
/// free -- and fail on the machine of anyone with a live session holding 5900.
/// Green where nobody looks and red where they do, which is the C# suite's
/// reasoning for pinning it the same way.
let pinPort = async () => {
  let probe = createServer()
  await Promise.make((resolve, _reject) => probe->listen(0, Config.vncHost.contents, () => resolve()))
  let port = (probe->address)["port"]
  await Promise.make((resolve, _reject) => probe->closeServer(() => resolve()))
  Config.vncPort := port
}

let started = []

/// A shell child that prints `ready` once it is, returned once it has.
///
/// Every child here has to reach some state before the assertion means anything,
/// and the tests this is modelled on used to wait for that by polling. A child
/// that says when it is ready removes the guess instead of enlarging it: the line
/// cannot be printed before the state exists, because the child prints it
/// afterwards. If the child dies first the pipe closes and nothing arrives, so a
/// broken child fails the test on the timeout rather than passing quietly.
///
/// `name` becomes the shell's `$0`, which is how a test puts a chosen string into
/// a real process's argv without needing a program that accepts one.
let sh = (script, ~name="sh", ~lines=1) =>
  Promise.make((resolve, _reject) => {
    let child = spawn("/bin/sh", ["-c", script, name], {"stdio": ["ignore", "pipe", "ignore"]})
    started->Array.push(child)
    let seen = []
    let buffer = ref("")
    child->stdout->setEncoding("utf8")
    child
    ->stdout
    ->onData("data", chunk => {
      buffer := buffer.contents ++ chunk
      let parts = buffer.contents->String.split("\n")
      buffer := parts->Array.at(-1)->Option.getOr("")
      parts
      ->Array.slice(~start=0, ~end=parts->Array.length - 1)
      ->Array.forEach(line =>
        if seen->Array.length < lines {
          seen->Array.push(line)
          if seen->Array.length == lines {
            resolve((child, seen))
          }
        }
      )
    })
  })

let reap = () => {
  started->Array.forEach(child =>
    switch child->killChild("SIGKILL") {
    | () => ()
    | exception _ => ()
    }
  )
  started->Array.length->ignore
}

/// The process state letter, read without disturbing it.
let state = pid =>
  Fs.readText(`/proc/${pid->Int.toString}/stat`)
  ->Option.map(stat =>
    stat
    ->String.split(")")
    ->Array.at(-1)
    ->Option.getOr("")
    ->String.split(" ")
    ->Array.filter(f => f != "")
    ->Array.get(0)
    ->Option.getOr("")
  )
  ->Option.getOr("")

/// A pid that is exited-but-unreaped, which is what Chrome leaves in the session.
///
/// `sh` normally reaps its own background children, which is why `true &` leaves
/// nothing behind -- but a shell under SIGSTOP cannot run the reaping, so the
/// `sleep` it backgrounded becomes a zombie and stays one. Nothing here is beyond
/// a POSIX shell, which matters: this port exists partly to drop dependencies,
/// and a suite that needed python to make a zombie would be carrying one.
let zombie = async () => {
  let (_, lines) = await sh(
    `sleep 1 &
echo $!
echo ready
kill -s STOP $$`,
    ~lines=2,
  )
  let pid = lines->Array.getUnsafe(0)->Int.fromString->Option.getOr(0)
  let found = ref(false)
  for _ in 1 to 300 {
    if !found.contents && state(pid) == "Z" {
      found := true
    } else if !found.contents {
      await Sessions.sleep(10)
    }
  }
  T.ok(found.contents)
  pid
}

let running = async () => {
  let (child, _) = await sh(`echo ready
while :; do sleep 1; done`)
  child->childPid
}

let record = (~chromePid=?, ~compositorPid=?, ~vncPid=?, ()): Sessions.session => {
  let self = 1
  {
    compositorPid: compositorPid->Option.getOr(self),
    chromePid: chromePid->Option.getOr(self),
    vncPid: vncPid->Option.getOr(self),
    vncHost: Config.vncHost.contents,
    vncPort: Config.vncPort.contents,
    ctlSocket: Sessions.ctlSocket(Config.vncPort.contents),
    waylandDisplay: "wayland-test",
  }
}

let write = (r: Sessions.session) => {
  Fs.mkdirp(Config.stateDir.contents)
  Fs.writeFileSync(
    Sessions.sessionFile(),
    [
      `compositor_pid=${r.compositorPid->Int.toString}`,
      `chrome_pid=${r.chromePid->Int.toString}`,
      `vnc_pid=${r.vncPid->Int.toString}`,
      `vnc_host=${r.vncHost}`,
      `vnc_port=${r.vncPort->Int.toString}`,
      `ctl_socket=${r.ctlSocket}`,
      `wayland_display=${r.waylandDisplay}`,
    ]->Array.join("\n"),
  )
}

let clean = () => {
  Sessions.alive := Sessions.readProcState
  Fs.delete(Sessions.sessionFile())
  Sessions.clearViewer()
}

// --- the record -------------------------------------------------------------

T.test("a record left by a cage session still parses", () => {
  // Ticket 063 renamed the key. A session that was already running when the
  // binary was upgraded is a real compositor still holding the port and the
  // profile, and the only thing that can tear it down is this record.
  let session = Sessions.sessionOf(
    Sessions.parseRecord(
      "cage_pid=4242\nchrome_pid=1\nvnc_pid=2\nvnc_host=127.0.0.1\n" ++
      "vnc_port=5900\nctl_socket=/tmp/x.sock\nwayland_display=wayland-9",
    ),
  )
  T.equal(session->Option.map(s => s.Sessions.compositorPid), Some(4242))
})

T.test("a malformed record reads as absent", () => {
  // The caller's next move is to start a fresh session either way, so a
  // half-written record must not raise on the way past.
  clean()
  Fs.mkdirp(Config.stateDir.contents)
  Fs.writeFileSync(Sessions.sessionFile(), "compositor_pid=1\nnot a pair\nvnc_port=")
  T.equal(Sessions.current(), None)
  clean()
})

// --- liveness ---------------------------------------------------------------

T.testAsync("a zombie does not count as alive", async () => {
  // The bug: signalling a pid with 0 succeeds on an unreaped child, so a session
  // whose Chrome had died inside cage reported itself live, and the viewer showed
  // a black screen with every status agreeing it was fine.
  let pid = await zombie()
  T.equal(state(pid), "Z") // the old check would still pass here
  T.ok(!Sessions.readProcState(pid))
})

T.testAsync("a running process is alive", async () => T.ok(Sessions.readProcState(await running())))

T.test("a pid that is not there is not alive", () =>
  T.ok(!Sessions.readProcState(4194304))
)

T.testAsync("a session whose chrome is gone is not live", async () => {
  // The black screen, exactly: the compositor and wayvnc still up, Chrome dead.
  // Liveness is keyed on Chrome because a compositor outliving it is the stale
  // state the record exists to detect.
  clean()
  let (dead, up) = (await zombie(), await running())
  write(record(~chromePid=dead, ~compositorPid=up, ~vncPid=up, ()))
  T.ok(Sessions.current()->Option.isSome)
  T.equal(Sessions.live(), None)
  clean()
})

// --- the port ---------------------------------------------------------------

T.testAsync("freePort takes the configured port when nothing holds it", async () => {
  await pinPort()
  T.equal(await Sessions.freePort(), Config.vncPort.contents)
})

T.testAsync("freePort steps over a port someone else holds", async () => {
  // Scanned rather than fixed so a second session -- or anyone else's wayvnc --
  // cannot silently take the port this one is about to advertise.
  //
  // The listener is this process, which is why no child is needed: the question
  // is only what the scan reads, not who is answering.
  await pinPort()
  let held = createServer()
  await Promise.make((resolve, _reject) =>
    held->listen(Config.vncPort.contents, Config.vncHost.contents, () => resolve())
  )
  let scanned = await Sessions.freePort()
  await Promise.make((resolve, _reject) => held->closeServer(() => resolve()))
  T.equal(scanned, Config.vncPort.contents + 1)
})

// A child that will not die at once: the trap runs only after the foreground
// `sleep` returns, and then sleeps again before exiting. So SIGTERM takes between
// one and two seconds to take effect, which is the whole point -- against a child
// that exits instantly these tests would pass even if `stopAll` never waited at
// all, and would be green for the wrong reason.
let slowScript = `trap 'sleep 1; exit 0' TERM
echo ready
while :; do sleep 1; done`

// And one that never leaves on its own. `trap '' TERM` ignores the signal
// outright, which is what a wayvnc wedged in a syscall looks like from here.
let stubbornScript = `trap '' TERM
echo ready
while :; do sleep 1; done`

T.testAsync("teardown waits for the process to actually go", async () => {
  // The port-drift regression. SIGTERM is asynchronous: a teardown that fired and
  // forgot left the old listener holding the port, so the session started
  // immediately afterwards quietly claimed a different one and the port climbed
  // on every restart.
  clean()
  let (slow, _) = await sh(slowScript)
  let pid = slow->childPid
  let began = Date.now()
  let _ = await Sessions.stopAll(record(~compositorPid=pid, ~vncPid=pid, ()))
  let elapsed = Date.now() -. began
  T.ok(!Sessions.readProcState(pid))
  T.ok(elapsed >= 900.0)
  clean()
})

T.testAsync("teardown kills what will not terminate", async () => {
  // The bug: the SIGTERM budget ran out and the record was unlinked anyway. That
  // is the port drift above all over again, and worse -- with the record gone the
  // surviving pid is unowned, so `reapStale` cannot clean up after it either.
  clean()
  let (child, _) = await sh(stubbornScript)
  let pid = child->childPid
  write(record(~compositorPid=pid, ~vncPid=pid, ()))
  T.equal(await Sessions.stopAll(record(~compositorPid=pid, ~vncPid=pid, ())), None)
  T.ok(!Sessions.readProcState(pid))
  T.equal(Sessions.current(), None)
  clean()
})

T.testAsync("a pid that survives even sigkill keeps its record", async () => {
  // Nothing in userspace survives SIGKILL, so liveness is stubbed here -- the
  // state is real (a pid in uninterruptible sleep, or one that is not ours) but
  // it cannot be produced honestly from a test.
  //
  // What matters is that the record stays: unlinking it is what makes the pid
  // unowned, and a record `reapStale` can still read is the only thing that keeps
  // the port attributable to a session someone can name.
  clean()
  let pid = await running()
  Sessions.alive := (_ => true)
  write(record(~compositorPid=pid, ~vncPid=pid, ()))
  let note = await Sessions.stopAll(record(~compositorPid=pid, ~vncPid=pid, ()))
  T.ok(note->Option.getOr("")->String.includes(pid->Int.toString))
  T.ok(Sessions.current()->Option.isSome)
  clean()
})

// --- the viewer -------------------------------------------------------------

T.testAsync("viewer pid is keyed on the pid not the name", async () => {
  // So a VNC client the user opened for something else is never mistaken for
  // ours, in either direction.
  let pid = await running()
  Sessions.recordViewer(pid)
  T.equal(Sessions.viewerPid(), Some(pid))
  Sessions.clearViewer()
  T.equal(Sessions.viewerPid(), None)
})

T.testAsync("a viewer that died is not reported", async () => {
  Sessions.recordViewer(await zombie())
  T.equal(Sessions.viewerPid(), None)
  Sessions.clearViewer()
})

T.testAsync("pidsRunning matches on the command line", async () => {
  // Matched on argv, so the fragment has to be unique to this run. A literal like
  // "nothing-runs-with-this" is not: it appears in this file, and therefore in
  // the argv of any shell that was handed this file's text -- which is how the
  // first draft of this test failed against the process that wrote it.
  //
  // The tag rides in as the shell's `$0`, so it is in a real process's cmdline
  // without needing a program that takes an arbitrary argument.
  let tag = "passenger-test-" ++ Math.floor(Date.now())->Float.toString
  let (child, _) = await sh(
    `echo ready
while :; do sleep 1; done`,
    ~name=tag,
  )
  T.ok(Sessions.pidsRunning(tag)->Array.includes(child->childPid))
  T.equal(Sessions.pidsRunning("absent-" ++ tag), [])
  reap()
})
