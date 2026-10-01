// Structural domain errors.
//
// Codes are stable so callers can branch on them without matching English, and
// the wire spelling is written out rather than derived from the constructor
// name -- a rename here must not silently change a caller's contract. That is
// the C# side's reasoning (`Errors.cs`) and it survives the port unchanged.
//
// SCREAMING_SNAKE is deliberate and is the one place this codebase does not use
// camelCase: an error code is a constant a caller matches on, not a field name,
// and an agent that learned to branch on `SCRIPT_RAISED` against the Python
// door, then the C# one, keeps working against this one.
//
// There used to be a CLI boundary that decided what a failure looked like on a
// terminal, and it was the only reader of `detail`. Ticket 057 deleted it and
// found what that had been hiding: nothing at the tool boundary catches, so the
// MCP SDK reported the message alone, and every remedy written into a detail --
// 042's list of which lanes are stuck and on what URLs, most carefully -- had
// never once reached an agent. `rendered` carries both now, and it is what the
// boundary throws.

type code =
  | DaemonNotRunning
  | DaemonStartFailed
  | AttachTimeout
  | PortInUse
  | SocketPathTooLong
  | ChromeNotFound
  | UnknownWindowBackend
  | NoPresenter
  | CannotHide
  | PageBlocked
  | HandoffTimeout
  | ScriptInvalid
  | ScriptRaised
  | ScriptReturnNotJson
  | TabNotFound
  | LaneNotFound

// `codeToString`, not `value`: the latter was `ErrorCodeNames.Value(this
// ErrorCode)` on the C# side, an extension-method name that means nothing here.
// Every wire spelling in this codebase is `<type>ToString` now, which is what
// the ReScript stdlib calls the same act (`Int.toString`).
//
// A `switch` with a case missing is a compile error here, which is what
// `CLAUDE.md` says the C# side bought by making blockers a base record with a
// discriminator. ReScript gives it without the workaround.
let codeToString = code =>
  switch code {
  | DaemonNotRunning => "DAEMON_NOT_RUNNING"
  | DaemonStartFailed => "DAEMON_START_FAILED"
  | AttachTimeout => "ATTACH_TIMEOUT"
  | PortInUse => "PORT_IN_USE"
  | SocketPathTooLong => "SOCKET_PATH_TOO_LONG"
  | ChromeNotFound => "CHROME_NOT_FOUND"
  | UnknownWindowBackend => "UNKNOWN_WINDOW_BACKEND"
  | NoPresenter => "NO_PRESENTER"
  | CannotHide => "CANNOT_HIDE"
  | PageBlocked => "PAGE_BLOCKED"
  | HandoffTimeout => "HANDOFF_TIMEOUT"
  | ScriptInvalid => "SCRIPT_INVALID"
  | ScriptRaised => "SCRIPT_RAISED"
  | ScriptReturnNotJson => "SCRIPT_RETURN_NOT_JSON"
  | TabNotFound => "TAB_NOT_FOUND"
  | LaneNotFound => "LANE_NOT_FOUND"
  }

/// Every failure this tool raises on purpose.
///
/// The C# side needed a class hierarchy -- DaemonException, ScriptException,
/// TabNotFoundException and the rest -- so that a `catch` could name a family.
/// Here the code *is* the discriminator and a `switch` on it is exhaustive, so
/// the hierarchy collapses into one exception carrying three fields. The
/// per-family constructors below survive, because what they were really doing
/// was fixing the wording of a failure in one place.
///
/// `message` is the plain half, without the code prefix or the detail, for a
/// caller rendering the parts separately -- which `Service` does on a failed
/// script. `detail` is what to do about it, when there is something.
exception Passenger({code: code, message: string, detail: option<string>})

/// The whole failure on one line: what the boundary reports when nobody catches.
let rendered = (code, message, detail) =>
  `[${codeToString(code)}] ${message}` ++
  switch detail {
  | Some(d) => ` -- ${d}`
  | None => ""
  }

let fail = (~detail=?, code, message) => throw(Passenger({code, message, detail}))

/// A page needs a human and we were told not to ask for one.
let blocked = (~blockerName, ~url) => Passenger({
  code: PageBlocked,
  message: `blocked by ${blockerName}`,
  detail: Some(url),
})

let handoffTimeout = (~blockerName, ~seconds) => Passenger({
  code: HandoffTimeout,
  message: `no human solved ${blockerName} within ${seconds->Int.toString}s`,
  detail: None,
})

/// The tab a call named is not in this lane.
///
/// Gone -- closed, or from a browser since restarted -- or open and owned by
/// somebody else, which a caller cannot tell apart and must not be able to. A
/// lane sees only its own tabs (ticket 040), so a tab id it was never given has
/// to be indistinguishable from one that does not exist; naming the difference
/// would leak the fact that another lane is holding something.
///
/// The detail used to list every open tab in the browser. Under lanes that is
/// both a leak and useless advice, since none of those ids would be usable.
let tabNotFound = (~tab, ~lane, ~openTabs) => Passenger({
  code: TabNotFound,
  message: `no tab ${tab} in lane ${lane}`,
  detail: Some(
    openTabs->Array.length > 0
      ? "open in this lane: " ++ openTabs->Array.join(", ")
      : "this lane has no tabs",
  ),
})

/// The lane a call named does not exist, or its clock ran out.
///
/// Not distinguished from "expired", deliberately: a lane whose TTL passed has
/// had its tabs closed, so there is nothing left for the caller to do with the
/// id either way. Both answers are "open a new one".
let laneNotFound = lane => Passenger({
  code: LaneNotFound,
  message: `no lane ${lane}`,
  detail: Some("it expired, or never existed; open one with openLane"),
})
