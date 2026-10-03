// What the VNC endpoint is measured to be, and what the presenters do when the
// measurement is "dead" (ticket 086).
//
// No C# oracle: this module never had a suite of its own, and the bug is newer
// than the port anyway. What is under test is the half of the handoff a human
// pays for -- the difference between "the session plans to serve VNC on this
// port" and "something is listening" -- which used to be no difference at all:
// wayvnc segfaulted eighty-two minutes into a live session, and every call a
// human's agent makes (`showBrowser`, `browserStatus`) reported the screen as
// working while the viewer sat on "reconnecting".
//
// State is redirected to a temp dir for the reason Sessions_test gives: a test
// that read the developer's real session record would assert against a machine
// it does not own. Liveness is stubbed to "everything is alive" so a record
// parses as a live session without a compositor to wait for.

@module("node:fs") external mkdtempSync: string => string = "mkdtempSync"
@module("node:os") external tmpdir: unit => string = "tmpdir"

Config.stateDir := mkdtempSync(tmpdir() ++ "/passenger-present-")

type server
@module("node:net") external createServer: unit => server = "createServer"
@send external listen: (server, int, string, unit => unit) => unit = "listen"
@send external closeServer: (server, unit => unit) => unit = "close"
@send external address: server => {"port": int} = "address"

/// A port nothing holds, for the sessions that are supposed to find it dead.
let freePort = async () => {
  let probe = createServer()
  await Promise.make((resolve, _reject) => probe->listen(0, Config.vncHost.contents, () => resolve()))
  let port = (probe->address)["port"]
  await Promise.make((resolve, _reject) => probe->closeServer(() => resolve()))
  port
}

/// A live session record naming `port`, in the session script's own spelling.
let writeRecord = (~vncPid, ~port) => {
  Fs.mkdirp(Config.stateDir.contents)
  Fs.writeFileSync(
    NestedSessions.sessionFile(),
    [
      "compositor_pid=1",
      "chrome_pid=1",
      `vnc_pid=${vncPid->Int.toString}`,
      `vnc_host=${Config.vncHost.contents}`,
      `vnc_port=${port->Int.toString}`,
      `ctl_socket=${NestedSessions.ctlSocket(port)}`,
      "wayland_display=wayland-test",
    ]->Array.join("\n"),
  )
}

let clean = () => {
  NestedSessions.alive := NestedSessions.readProcState
  Fs.delete(NestedSessions.sessionFile())
  NestedSessions.coredumpDir := "/var/lib/systemd/coredump"
}

/// What `requireVnc` did, as data rather than as a throw.
let refusal = async () =>
  switch await Present.requireVnc() {
  | () => None
  | exception Errors.Passenger({code, message, detail}) => Some((code, message, detail))
  }

T.testAsync("with no session there is no VNC endpoint at all", async () => {
  clean()
  NestedSessions.alive := (_ => true)
  // `none`, not `dead`: nothing was ever planned, so there is nothing to
  // mourn -- and nothing to refuse, which is the presenters' own case.
  T.equal(await Present.vncState(), "none")
  await Present.requireVnc()
})

T.testAsync("a live session whose port nothing answers is dead", async () => {
  clean()
  NestedSessions.alive := (_ => true)
  let port = await freePort()
  writeRecord(~vncPid=4242, ~port)
  T.equal(await Present.vncState(), "dead")
  // Refused, and the refusal names the endpoint it would have handed over.
  switch await refusal() {
  | None => T.ok(false) // a dead endpoint was presented as a working handoff
  | Some((code, message, detail)) =>
    T.equal(code, VncNotServing)
    T.ok(message->String.includes(port->Int.toString))
    let d = detail->Option.getOr("")
    T.ok(d->String.includes("4242")) // the pid that is gone
    T.ok(d->String.includes("session.log")) // where whatever it said would be
  }
})

T.testAsync("a live session with something listening is serving", async () => {
  clean()
  NestedSessions.alive := (_ => true)
  let held = createServer()
  await Promise.make((resolve, _reject) => held->listen(0, Config.vncHost.contents, () => resolve()))
  let port = (held->address)["port"]
  writeRecord(~vncPid=4242, ~port)
  T.equal(await Present.vncState(), `serving ${Config.vncHost.contents}:${port->Int.toString}`)
  // The one case where a viewer URL is a promise the tool can keep.
  await Present.requireVnc()
  await Promise.make((resolve, _reject) => held->closeServer(() => resolve()))
})

T.testAsync("a dead wayvnc with a core to its name says it crashed", async () => {
  // A segfault writes no stderr, so the session log -- drained since ticket
  // 066 -- says nothing about it, and the process table says only "gone". The
  // core file's name is the one place the death is named, and naming it is
  // what turns "VNC is missing" into "VNC is missing because it crashed".
  clean()
  NestedSessions.alive := (_ => true)
  let port = await freePort()
  writeRecord(~vncPid=4242, ~port)
  let cores = mkdtempSync(tmpdir() ++ "/passenger-cores-")
  Fs.writeFileSync(Fs.join(cores, "core.wayvnc.1000.39be04cd.4242.1791022620000000.zst"), "core")
  NestedSessions.coredumpDir := cores
  switch await refusal() {
  | None => T.ok(false)
  | Some((code, _, detail)) =>
    T.equal(code, VncNotServing)
    T.ok(detail->Option.getOr("")->String.includes("crashed"))
  }
  clean()
})

T.testAsync("a core from an earlier wayvnc is not this one's cause", async () => {
  // The false attribution this check was first written with: any
  // `core.wayvnc.*` file is a file an earlier crash left behind, and naming it
  // blames this death on that one. Two waysvnc dying at different times is the
  // ordinary case on a machine that leaves its cores around.
  clean()
  NestedSessions.alive := (_ => true)
  let port = await freePort()
  writeRecord(~vncPid=4242, ~port)
  let cores = mkdtempSync(tmpdir() ++ "/passenger-cores-")
  Fs.writeFileSync(Fs.join(cores, "core.wayvnc.1000.39be04cd.787512.1791022620000000.zst"), "core")
  NestedSessions.coredumpDir := cores
  switch await refusal() {
  | None => T.ok(false)
  | Some((code, _, detail)) =>
    T.equal(code, VncNotServing)
    T.ok(!(detail->Option.getOr("")->String.includes("crashed")))
  }
  clean()
})

T.testAsync("a dead wayvnc with no core says less, not nothing", async () => {
  // The clause is conditional on the evidence existing: on a machine with no
  // systemd-coredump, or a wayvnc that exited cleanly, the refusal is the
  // same refusal without the crash -- an invented cause is the same lie.
  clean()
  NestedSessions.alive := (_ => true)
  let port = await freePort()
  writeRecord(~vncPid=4242, ~port)
  NestedSessions.coredumpDir := mkdtempSync(tmpdir() ++ "/passenger-cores-")
  switch await refusal() {
  | None => T.ok(false)
  | Some((code, _, detail)) =>
    T.equal(code, VncNotServing)
    T.ok(!(detail->Option.getOr("")->String.includes("crashed")))
  }
  clean()
})
