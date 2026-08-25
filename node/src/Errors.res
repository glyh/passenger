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

type code =
  | DaemonNotRunning
  | DaemonStartFailed
  | AttachTimeout
  | PortInUse
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

// A `switch` with a case missing is a compile error here, which is what
// `CLAUDE.md` says the C# side bought by making blockers a base record with a
// discriminator. ReScript gives it without the workaround.
let value = code =>
  switch code {
  | DaemonNotRunning => "DAEMON_NOT_RUNNING"
  | DaemonStartFailed => "DAEMON_START_FAILED"
  | AttachTimeout => "ATTACH_TIMEOUT"
  | PortInUse => "PORT_IN_USE"
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

exception Passenger({code: code, message: string})
