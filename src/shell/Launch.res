// Imperative shell: how Chrome is launched so that it starts out hidden.
//
// Deliberately NOT headless: headless changes the fingerprint (no GPU, software
// WebGL, no window) and makes human handoff impossible. The window stays fully
// real -- it is just parked somewhere you aren't looking.
//
// There is no standard Wayland protocol for a window to hide itself, and the
// compositor-specific ways of doing it are unportable and prone to breaking, so
// there is exactly one real mechanism here plus a null object for when its
// dependencies are missing. Override the choice with PASSENGER_WM.
//
// The compositor is sway, and was cage until ticket 063. cage is a kiosk: one
// output, one fullscreened window, and no way to ask it for anything. Three
// tickets were each paying for that separately -- no data-control protocol, so
// wayvnc's clipboard had nothing to talk to (062); no text-input or
// input-method, so no IME could run in the session at all (062); one output
// forever, so two humans could never be handed two screens (041). It also
// fullscreens what it starts, which is why 006 had to spend a CDP call undoing
// half of it. sway costs 33 MiB more in the closure, offers all three, and
// answers on a socket.
//
// That reintroduces the compositor IPC this project deleted twice -- hyprctl
// and wlrctl backends both broke. The difference is ownership: those spoke to
// the *host's* compositor, upgraded on someone else's schedule. This sway is
// ours, pinned in flake.lock, running a config written here on every start.
//
// Showing the browser to a human is a separate concern -- see Present.

open Models

let wmClass = "passenger"

let sessionSh = () => Fs.join(Config.stateDir.contents, "session.sh")

/// The generated sway config, rewritten on every start.
let sessionConf = () => Fs.join(Config.stateDir.contents, "sway.conf")

/// The output everything agrees on: sway creates it, wayvnc serves it, and
/// `Geometry` scales it.
///
/// A constant because there are now two places that must name the same one. cage
/// had exactly one output and wayvnc could take whatever it found; under sway
/// `create_output` can add a second (which is what 041 wants), so serving "the
/// only one there is" stops being a description.
let output = "HEADLESS-1"

/// The output's starting mode, and cage's old default kept deliberately.
///
/// The README's measured fingerprint says `screen: 1280x720`, so changing it here
/// would move something a site can read. The viewer resizes it over RFB straight
/// afterwards anyway (002, 003) -- this is only what the framebuffer is before
/// anyone looks.
let mode = "1280x720"

let sessionScript = () => Assets.read("session/session.sh")

/// Attaching the human's own IME to the session, or nothing at all.
///
/// Without this a human handed the browser could not type Chinese into it: sway
/// offers `text_input_v3` and `input_method_v2` since ticket 063, and nothing was
/// there to *be* an input method. Chrome needed no argument -- it already speaks
/// the protocol -- so the whole fix is one D-Bus call.
///
/// **The human's own fcitx5, not a second one.** The first version started a
/// private instance on a private bus, against a copy of `~/.config/fcitx5`, and
/// the owner asked the obvious question: why not reuse the one already running?
/// fcitx5 exposes `OpenWaylandConnection` for exactly this -- one process serving
/// several compositors -- so the session gets the real config and the real
/// learned dictionary, live.
let imeScript = () => Assets.read("session/ime.sh")

/// The IME lines for a session, or a comment saying why there are none.
///
/// No IME is an ordinary outcome rather than a failure: `PASSENGER_IME=none` asks
/// for none, and a machine whose fcitx5 is not running answers the call with an
/// error the log records. Pure, and separated from the PATH lookup, so both
/// answers are testable wherever the suite happens to run.
let imeSection = (command, ~available) =>
  command == "none" || command == "" || !available
    ? "# no input method (PASSENGER_IME)"
    : imeScript()

/// The sway config, which exists to make sway behave like the kiosk cage was.
///
/// No bar, no keybindings, no decorations: the human who takes over a handoff
/// should find a browser, not a window manager they did not ask for, and a stray
/// keystroke should not be able to reach a compositor command.
///
/// **The absence of keybindings is the point, and it is guaranteed by two
/// things.** sway has none compiled in -- every binding comes from a config --
/// and `-c` means the one the distribution ships is never read. So the compositor
/// here composites and nothing else, and every key the human presses belongs to
/// the browser. Adding a `bindsym` would quietly take one back, which is why a
/// test asserts there are none.
let sessionConfig = () => Assets.read("session/sway.conf")

// --- finding programs -------------------------------------------------------

/// Is this path executable by somebody?
let isExecutable = path =>
  switch Fs.statSync(path) {
  // 0o111: the three execute bits. Node reports the raw st_mode, so this is the
  // same test `File.GetUnixFileMode` was spelling out on the C# side.
  | stats => Int.bitwiseAnd(Fs.mode(stats), 0o111) != 0
  | exception _ => false
  }

/// Where a program is on PATH, or `None`. `shutil.which`, which neither .NET nor
/// Node has an equivalent of.
let which = program =>
  if program->String.includes("/") {
    Fs.existsSync(program) && isExecutable(program) ? Some(program) : None
  } else {
    let found = ref(None)
    Config.raw("PATH")
    ->Option.getOr("")
    ->String.split(":")
    ->Array.filter(d => d != "")
    ->Array.forEach(dir =>
      if found.contents->Option.isNone {
        let candidate = Fs.join(dir, program)
        if Fs.existsSync(candidate) && isExecutable(candidate) {
          found := Some(candidate)
        }
      }
    )
    found.contents
  }

// --- the backends -----------------------------------------------------------

type backend = {
  name: backendName,
  available: unit => bool,
  prepare: unit => unit,
  /// Async where the C# interface was synchronous, and for one reason: the port
  /// a session advertises is claimed by scanning for a free one, and asking
  /// whether a TCP port is taken is asynchronous in this runtime. The third
  /// signature the runtime changed, after `Lanes.chromeTabs` and `Session`'s
  /// attach. What is planned is unchanged.
  plan: array<string> => promise<launchPlan>,
}

/// What this session *is*, said to Chrome rather than hoped for.
///
/// The session serves Wayland and nothing else: `WLR_BACKENDS=headless`, no DRM
/// master, no X server. Chrome was never told, and on the machine this was
/// written on it came up as a Wayland client anyway -- because the developer's
/// `~/.config/chrome-flags.conf` happened to say `--ozone-platform-hint=auto`,
/// which the distribution's wrapper splices into argv. On any host without that
/// file Chrome would fall back to X11, which in here means Xwayland or, where the
/// closure has none, a browser that never starts (ticket 061).
///
/// Unconditional, and only in this backend. There is no X to fall back to inside
/// the session, so nothing is being closed off that was reachable; `--visible`
/// still hands the host's own desktop whatever it prefers.
let platform = ["--ozone-platform=wayland"]

/// Chrome inside its own sway compositor, viewed over VNC on demand.
///
/// The host compositor is not involved, so nothing here breaks when you switch
/// compositors -- or when one of them rewrites the IPC a backend depended on. The
/// IPC this one speaks is its own sway's, started here and pinned with the rest
/// of the closure (ticket 063).
let nested = {
  name: Nested,
  // swaymsg as well as sway: the session script uses it to bring the compositor
  // down when Chrome goes, and a sway without it would leave one running behind
  // a dead browser.
  available: () =>
    which("sway")->Option.isSome &&
    which("swaymsg")->Option.isSome &&
    which("wayvnc")->Option.isSome,
  prepare: () => (),
  plan: async argv => {
    Fs.mkdirp(Config.stateDir.contents)
    // Claimed per session rather than fixed: a second session that reused the
    // port would lose the bind, leaving the *stale* wayvnc serving an empty
    // compositor to anyone who connected.
    let port = await NestedSessions.freePort()
    let ctl = NestedSessions.ctlSocket(port)
    // Checked here, not inside `ctlSocket`, which stays a pure path composer:
    // the 107 is not a property of the string but of `sun_path` -- the
    // 108-byte buffer, NUL included, the kernel binds a unix socket from -- and
    // this is where the path is about to be handed to one. Past it wayvnc dies
    // with "File name too long" into a pipe nobody reads, and the session comes
    // up with a compositor and no VNC, reporting itself fine (ticket 064). The
    // message names the limit and the length so whoever set PASSENGER_STATE can
    // see how far past it they are; the path says which variable did it.
    let ctlLen = String.length(ctl)
    if ctlLen > 107 {
      Errors.fail(
        SocketPathTooLong,
        `the control socket path is ${ctlLen->Int.toString} bytes and a unix socket path stops at 107`,
        ~detail=ctl,
      )
    }
    // After argv[0], so the browser being launched is still the first word and a
    // reader of the generated script sees which one it is.
    let full =
      [argv->Array.get(0)->Option.getOr("")]
      ->Array.concat(platform)
      ->Array.concat(argv->Array.slice(~start=1, ~end=argv->Array.length))
    let quoted = full->Array.map(a => `'${a}'`)->Array.join(" ")
    let ime = imeSection(Config.imeCommand.contents, ~available=which("dbus-send")->Option.isSome)

    Fs.writeFileSync(
      sessionSh(),
      sessionScript()
      ->String.replaceAll("{state}", Config.stateDir.contents)
      ->String.replaceAll("{ime}", ime)
      ->String.replaceAll("{ctl}", ctl)
      ->String.replaceAll("{host}", Config.vncHost.contents)
      ->String.replaceAll("{port}", port->Int.toString)
      ->String.replaceAll("{record}", NestedSessions.sessionFile())
      ->String.replaceAll("{output}", output)
      ->String.replaceAll("{chrome}", quoted),
    )
    Fs.chmodSync(sessionSh(), 0o755)
    // sway starts the session script from the config rather than taking it as an
    // argument the way `cage -- script` did. There is no way to hand it one: the
    // display name is not known until sway has picked it, so the script has to be
    // started from inside, which is exactly where it needs to be to read
    // WAYLAND_DISPLAY back out.
    Fs.writeFileSync(
      sessionConf(),
      sessionConfig()
      ->String.replaceAll("{output}", output)
      ->String.replaceAll("{mode}", mode)
      ->String.replaceAll("{script}", sessionSh()),
    )

    // Headless wlroots still renders through the GPU render node, so WebGL keeps
    // reporting the real adapter.
    {
      argv: ["sway", "-c", sessionConf()],
      env: Dict.fromArray([("WLR_BACKENDS", "headless"), ("WLR_LIBINPUT_NO_DEVICES", "1")]),
    }
  },
}

/// No mechanism available; the window simply stays visible.
let noOp = {
  name: NoBackend,
  available: () => true,
  prepare: () => (),
  plan: async argv => {argv, env: Dict.make()},
}

let build = name =>
  switch name {
  | Nested => nested
  | NoBackend => noOp
  }

let autoOrder = [Nested, NoBackend]

let select = () =>
  switch Config.raw("PASSENGER_WM") {
  | Some(forced) =>
    switch parseBackend(forced) {
    | Some(name) => build(name)
    | None =>
      throw(
        Errors.Passenger({
          code: UnknownWindowBackend,
          message: `unknown backend '${forced}'`,
          detail: Some(backendNames->Array.join(", ")),
        }),
      )
    }
  | None =>
    switch autoOrder->Array.map(build)->Array.find(b => b.available()) {
    | Some(backend) => backend
    | None => noOp
    }
  }
