// What the nested backend writes before anything starts.
//
// The oracle was `tests/Passenger.Tests/LaunchTests.cs`, all twelve cases; that
// tree is gone with ticket 071 and these are the cases now. `plan`
// is the one part of the launch path that can be checked without a compositor:
// it is a nearly-pure function from the Chrome argv to two generated files and an
// argv, and everything it gets wrong is invisible until a real session comes up
// wrong. Ticket 063 moved it from cage to sway, which split what used to be one
// file into a config and a script that have to agree with each other.
//
// A thirteenth case lived here for as long as two trees did: the assets were
// copied from the C# side's embedded ones, and it compared the copies so an edit
// to one that missed the other failed rather than shipping a session script and
// a sway config that disagree. It was written to delete itself when the C# tree
// went, and ticket 071 took both.

@module("node:fs") external mkdtempSync: string => string = "mkdtempSync"
@module("node:os") external tmpdir: unit => string = "tmpdir"

Config.stateDir := mkdtempSync(tmpdir() ++ "/passenger-launch-")

let planned = async () => {
  let plan = await Launch.nested.plan(["chrome", "about:blank"])
  (
    plan,
    Fs.readText(Launch.sessionConf())->Option.getOr(""),
    Fs.readText(Launch.sessionSh())->Option.getOr(""),
  )
}

T.testAsync("sway is started on the generated config", async () => {
  let (plan, config, _) = await planned()
  T.equal(plan.argv, ["sway", "-c", Launch.sessionConf()])
  // The script cannot be passed as an argument the way `cage -- script` took it,
  // so the config has to be the thing that starts it.
  T.ok(config->String.includes(`exec ${Launch.sessionSh()}`))
})

T.testAsync("the config and the script name the same output", async () => {
  let (_, config, script) = await planned()
  // Two files now have an opinion about which output exists, and wayvnc serving
  // one that sway did not create is a black screen with everything reporting
  // healthy -- the exact failure this project started from.
  T.ok(config->String.includes(`output ${Launch.output} resolution ${Launch.mode}`))
  T.ok(script->String.includes(`-o ${Launch.output}`))
})

T.testAsync("the compositor is told to go when chrome does", async () => {
  let (_, _, script) = await planned()
  // cage exited with its child and sway does not, so this is the line that keeps
  // a dead Chrome from leaving a live compositor holding the port.
  T.ok(script->String.includes(`wait "$chrome_pid"`))
  T.ok(script->String.includes("swaymsg exit"))
})

T.testAsync("the compositor binds no keys", async () => {
  let (_, config, _) = await planned()
  // sway is here to composite and for nothing else: every key the human presses
  // in a handoff belongs to the browser. sway has no bindings compiled in and
  // `-c` keeps the distribution's config out, so the only way one arrives is
  // someone adding it here.
  //
  // Directives only: a comment is free to name what it promises not to do, and
  // the first version of this test caught the comment saying so.
  let directives =
    config
    ->String.split("\n")
    ->Array.map(l => l->String.trim)
    ->Array.filter(l => l != "" && !(l->String.startsWith("#")))
  ["bindsym", "bindcode", "bindswitch", "bindgesture", "floating_modifier"]->Array.forEach(verb =>
    T.ok(!(directives->Array.some(l => l->String.includes(verb))))
  )
})

T.testAsync("chrome's argv is quoted into the script", async () => {
  let (_, _, script) = await planned()
  // A URL with a shell metacharacter in it is an ordinary URL.
  T.ok(script->String.includes("'chrome' '--ozone-platform=wayland' 'about:blank' &"))
})

T.testAsync("chrome is told which platform it is launching into", async () => {
  let (_, _, script) = await planned()
  // The session serves Wayland and nothing else. Chrome used to be left to work
  // that out, and did -- from a flag the developer's personal chrome-flags.conf
  // happened to supply. On any other host it would have fallen back to X11,
  // meaning Xwayland or nothing at all.
  T.ok(script->String.includes("'--ozone-platform=wayland'"))
})

T.testAsync("the host's chrome flags file is kept out of the session", async () => {
  let (_, _, script) = await planned()
  // The distribution's wrapper splices $XDG_CONFIG_HOME/chrome-flags.conf into
  // argv, so a personal dotfile was deciding what the nested browser was -- down
  // to --touch-events, which a page can read.
  T.ok(script->String.includes(`XDG_CONFIG_HOME="$chrome_config"`))
  T.ok(script->String.includes("chrome-flags.conf"))
  // A mirror, not a blank: the fonts and the fontconfig that picks them are the
  // whole reason this tool runs on the host rather than in a container.
  T.ok(script->String.includes("ln -s"))
})

T.test("the ime is the human's own", () => {
  // Not a second instance: the fcitx5 already running for the human's desktop is
  // asked to serve this display as well, so the session gets the real config and
  // the real learned dictionary rather than a copy.
  let section = Launch.imeSection("fcitx5", ~available=true)
  T.ok(section->String.includes("OpenWaylandConnection"))
  T.ok(section->String.includes("$WAYLAND_DISPLAY"))
  T.ok(!(section->String.includes("dbus-run-session")))
  T.ok(!(section->String.includes("XDG_CONFIG_HOME")))
})

T.test("no ime is an ordinary outcome", () => {
  // Asked for none, and none to be had: both are a session that simply cannot
  // compose, which is what every session was before ticket 066.
  T.ok(!(Launch.imeSection("none", ~available=true)->String.includes("dbus-run-session")))
  T.ok(!(Launch.imeSection("fcitx5", ~available=false)->String.includes("dbus-run-session")))
})

T.testAsync("no placeholder survives into what is written", async () => {
  let (_, config, script) = await planned()
  // `{state}` once outlived its only user and reached the disk in the script's
  // very first line -- a redirect into a directory named "{state}", which kills
  // the shell before it can say so. The session came up with a compositor, no
  // browser, and no log to explain it.
  [config, script]->Array.forEach(written =>
    switch written->String.match(%re("/\{[a-z][a-z0-9_]*\}/")) {
    // Named in the failure rather than merely counted, because the useful half
    // of this test is *which* placeholder was never substituted.
    | Some(m) => T.equal(m->Array.get(0)->Option.getOr(None), None)
    | None => T.ok(true)
    }
  )
})

T.testAsync("the session keeps a log", async () => {
  let (_, _, script) = await planned()
  // Everything the session said about itself used to go to /dev/null, which is
  // how a wayvnc that could not bind and a compositor that refused to exit both
  // passed for a healthy session.
  T.ok(script->String.includes("session.log"))
  T.ok(script->String.includes("swaymsg exit || echo"))
})

T.testAsync("the script is executable", async () => {
  let _ = await planned()
  T.ok(Launch.isExecutable(Launch.sessionSh()))
})

T.testAsync("a control socket path the kernel cannot take is refused", async () => {
  // A unix socket path lives in `sun_path`, 108 bytes on Linux with the NUL
  // counted, and one byte past that wayvnc dies with "File name too long" into
  // a pipe nobody reads -- the session then reports itself fine with a
  // compositor and no VNC at all (ticket 064). So the plan refuses the path
  // instead of composing files nothing can bind.
  let saved = Config.stateDir.contents
  let deep = saved ++ "/" ++ String.repeat("deep", 30)
  Config.stateDir := deep
  // Pinned to a five-digit port so the length the refusal names is knowable
  // here: `freePort` scans upward from this, and every port it can land on has
  // the same width. Restored before anything asserts, so a failed assertion
  // cannot leave a mutated config for the cases after this one.
  let savedPort = Config.vncPort.contents
  Config.vncPort := 25900
  let outcome = switch await planned() {
  | _ => None
  | exception Errors.Passenger({code, message}) => Some((code, message))
  }
  Config.stateDir := saved
  Config.vncPort := savedPort
  switch outcome {
  | None => T.ok(false) // the plan accepted a path no one can bind
  | Some((code, message)) =>
    T.equal(code, SocketPathTooLong)
    // The two numbers and the code, and no prose: wording is free to change.
    // The length is checked against the composed path -- deep ++ "/" ++
    // "wayvnc-" ++ five digits ++ ".sock" is 18 bytes past the state dir.
    T.ok(message->String.includes("107"))
    T.ok(message->String.includes(Int.toString(String.length(deep) + 18)))
  }
})
