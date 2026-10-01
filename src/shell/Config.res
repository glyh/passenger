// Imperative shell: the environment boundary.
//
// Every PASSENGER_* variable is read exactly once, here. No other module
// touches the environment (except Launch's backend override, which must be read
// before a backend exists to hold it).
//
// The C# side froze these into one record and gave `Config.Settings` a setter so
// the test suite could swap the whole thing. Here each setting is its own `ref`,
// for the same purpose reached the shorter way: a suite points the state
// directory at a temp path before anything opens the registry, so it never
// writes a developer's real `lanes.db`. The `unit ->` on the derived paths is
// what keeps that honest -- read a ref once into a `let` at module level and a
// test's later assignment would not be seen.

@val @scope("process") external env: Dict.t<string> = "env"

/// Unset and empty are the same thing: `PASSENGER_VNC_SCALE=` is somebody
/// clearing it, not somebody asking for the empty string.
let raw = name =>
  switch env->Dict.get(name) {
  | Some("") => None
  | other => other
  }

@module("node:os") external homedir: unit => string = "homedir"
@module("node:path") external joinPath: (string, string) => string = "join"

// Coerced here rather than by a validating layer, and a value that will not
// parse falls back to the default: this is start-up, and a typo'd
// PASSENGER_PORT should not be the reason nothing runs.
let int = (name, fallback, low, high) =>
  switch raw(name)->Option.flatMap(s => Int.fromString(s)) {
  | Some(parsed) if parsed >= low && parsed <= high => parsed
  | _ => fallback
  }

let stateDir = ref(
  switch raw("PASSENGER_STATE") {
  | Some(dir) => dir
  | None => homedir()->joinPath(".local")->joinPath("share")->joinPath("passenger")
  },
)

let cdpPort = ref(int("PASSENGER_PORT", 9222, 1, 65535))
let chromeBin = ref(raw("PASSENGER_CHROME")->Option.getOr("google-chrome-stable"))
let handoffTimeoutS = ref(int("PASSENGER_HANDOFF_TIMEOUT", 300, 1, 2147483647))

/// How long to wait for an attach before treating the browser as stuck.
/// Attaching initialises every open tab, so this is really a budget for the
/// slowest one.
let attachTimeoutS = ref(int("PASSENGER_ATTACH_TIMEOUT", 15, 1, 2147483647))

/// How long the browser may sit with nobody using it before it is stopped,
/// and everything spawned with it taken down. Chrome starts on demand and
/// nothing else ever ended it, so a laptop that read one page at 10:00 used
/// to run the whole nested stack until shutdown; the reaper (ticket 076) is
/// what closes that. Zero is `Lanes.noTtl`'s spelling carried over: never.
/// The blind horizon -- reaping a browser that stopped answering -- is
/// derived from this one, 8x, so one variable governs both and "never"
/// cannot be argued with half of.
let idleStopS = ref(int("PASSENGER_IDLE_STOP", 2700, 0, 2147483647))

let vncHost = ref(raw("PASSENGER_VNC_HOST")->Option.getOr("127.0.0.1"))
let vncPort = ref(int("PASSENGER_VNC_PORT", 5900, 1, 65535))

/// The viewer asks for the framebuffer size it needs, so there is nothing to
/// pin here. The scale it cannot ask for: unset means "match the host screen",
/// and setting it overrides that.
let vncScale = ref(
  switch raw("PASSENGER_VNC_SCALE")->Option.flatMap(s => Float.fromString(s)) {
  | Some(scale) if scale > 0.0 => Some(scale)
  | _ => None
  },
)

let novncPort = ref(int("PASSENGER_NOVNC_PORT", 6080, 1, 65535))

/// Where noVNC's modules live. Set by the flake to a store path holding only
/// the static files; unset means "look in the usual system places".
let novncDir = ref(raw("PASSENGER_NOVNC"))

/// The browser the viewer window is opened in, which is the host's, not the
/// nested one -- though by default it is the same binary.
let viewerBrowser = ref(raw("PASSENGER_VIEWER"))

/// Whether the session asks the human's IME to serve it: `fcitx5`, or `none`.
///
/// **Defaults to `none`, because it crashes Chrome** (ticket 067). Measured
/// twice on fresh profiles, one variable apart: with no IME the browser ran out
/// a full minute clean, and with the IME attached it segfaulted within a second.
/// Attaching a separate fcitx5 instance by hand crashed it the same way, so this
/// is about an input method being present at all rather than about reusing the
/// human's one.
///
/// The mechanism stays, off, because it is one D-Bus call and it demonstrably
/// works as an input method -- typed into, by hand, before it was wired in. What
/// is not understood is why Chrome dies, and shipping a browser that does not
/// start is worse than shipping one that cannot compose.
let imeCommand = ref(raw("PASSENGER_IME")->Option.getOr("none"))

let presenter = ref(raw("PASSENGER_PRESENTER")->Option.flatMap(Models.parsePresenter))
let webhookUrl = ref(raw("PASSENGER_WEBHOOK"))

@val @scope("process") external getuid: unit => int = "getuid"

/// Where the Wayland sockets live, for talking to the nested session.
let runtimeDir = () =>
  switch raw("XDG_RUNTIME_DIR") {
  | Some(dir) => dir
  | None => `/run/user/${getuid()->Int.toString}`
  }

let profileDir = () => joinPath(stateDir.contents, "chrome-profile")

/// A profile of its own for the window the browser is watched in.
///
/// Separate from the user's everyday browser for two reasons. It keeps a
/// takeover window out of their session entirely, and it is what makes the
/// window ours to close: launched into an already-running Chrome, the process we
/// started hands the window over and exits, leaving nothing to track or dismiss.
let viewerProfile = () => joinPath(stateDir.contents, "viewer-profile")

let reportsDir = () => joinPath(stateDir.contents, "reports")

let cdpUrl = () => `http://127.0.0.1:${cdpPort.contents->Int.toString}`

/// The page, without the endpoint: that is per-session, so Present appends it
/// from the live record rather than from settings.
let viewerUrl = () => `http://${vncHost.contents}:${novncPort.contents->Int.toString}/`
