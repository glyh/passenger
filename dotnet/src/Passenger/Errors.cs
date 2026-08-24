// Structural domain errors.
//
// Core modules raise these; only the CLI boundary decides what a failure looks
// like on a terminal. Codes are stable so callers can branch on them without
// matching English.

namespace Passenger;

public enum ErrorCode
{
    DaemonNotRunning,
    DaemonStartFailed,
    AttachTimeout,
    PortInUse,
    ChromeNotFound,
    UnknownWindowBackend,
    NoPresenter,
    CannotHide,
    PageBlocked,
    HandoffTimeout,
    ScriptInvalid,
    ScriptRaised,
    ScriptReturnNotJson,
    TabNotFound,
    LaneNotFound,
}

public static class ErrorCodeNames
{
    /// <summary>
    /// The wire spelling of a code.
    ///
    /// The one place this port does not use camelCase, and deliberately: an error
    /// code is a constant a caller matches on, not a field name, and
    /// SCREAMING_SNAKE is what that convention looks like everywhere it appears --
    /// including in the Python these were taken from, so an agent that learned to
    /// branch on `SCRIPT_RAISED` keeps working.
    ///
    /// Written out rather than derived from the enum name so a rename here cannot
    /// silently change a caller's contract.
    /// </summary>
    public static string Value(this ErrorCode code) => code switch
    {
        ErrorCode.DaemonNotRunning => "DAEMON_NOT_RUNNING",
        ErrorCode.DaemonStartFailed => "DAEMON_START_FAILED",
        ErrorCode.AttachTimeout => "ATTACH_TIMEOUT",
        ErrorCode.PortInUse => "PORT_IN_USE",
        ErrorCode.ChromeNotFound => "CHROME_NOT_FOUND",
        ErrorCode.UnknownWindowBackend => "UNKNOWN_WINDOW_BACKEND",
        ErrorCode.NoPresenter => "NO_PRESENTER",
        ErrorCode.CannotHide => "CANNOT_HIDE",
        ErrorCode.PageBlocked => "PAGE_BLOCKED",
        ErrorCode.HandoffTimeout => "HANDOFF_TIMEOUT",
        ErrorCode.ScriptInvalid => "SCRIPT_INVALID",
        ErrorCode.ScriptRaised => "SCRIPT_RAISED",
        ErrorCode.ScriptReturnNotJson => "SCRIPT_RETURN_NOT_JSON",
        ErrorCode.TabNotFound => "TAB_NOT_FOUND",
        ErrorCode.LaneNotFound => "LANE_NOT_FOUND",
        _ => throw new ArgumentOutOfRangeException(nameof(code)),
    };
}

/// <summary>Base for every failure this tool raises on purpose.</summary>
public class PassengerException : Exception
{
    public ErrorCode Code { get; }

    /// <summary>The message without the code prefix, for a frontend to render.</summary>
    public string PlainMessage { get; }

    public string? Detail { get; }

    public PassengerException(ErrorCode code, string message, string? detail = null,
                              Exception? inner = null)
        : base($"[{code.Value()}] {message}", inner)
    {
        Code = code;
        PlainMessage = message;
        Detail = detail;
    }
}

/// <summary>The Chrome daemon is missing, unstartable, or contested.</summary>
public sealed class DaemonException(ErrorCode code, string message, string? detail = null,
                                    Exception? inner = null)
    : PassengerException(code, message, detail, inner);

/// <summary>The window backend could not do what was asked.</summary>
public sealed class WindowException(ErrorCode code, string message, string? detail = null,
                                    Exception? inner = null)
    : PassengerException(code, message, detail, inner);

/// <summary>A page needs a human and we were told not to ask for one.</summary>
public sealed class BlockedException(string blockerName, string url)
    : PassengerException(ErrorCode.PageBlocked, $"blocked by {blockerName}", url)
{
    public string BlockerName { get; } = blockerName;
    public string Url { get; } = url;
}

public sealed class HandoffTimeoutException(string blockerName, int seconds)
    : PassengerException(ErrorCode.HandoffTimeout,
                         $"no human solved {blockerName} within {seconds}s")
{
    public string BlockerName { get; } = blockerName;
    public int Seconds { get; } = seconds;
}

/// <summary>A caller's script would not compile, raised, or returned a handle.</summary>
public sealed class ScriptException(ErrorCode code, string message, string? detail = null,
                                    Exception? inner = null)
    : PassengerException(code, message, detail, inner);

/// <summary>
/// The tab a call named is not in this lane.
///
/// Gone -- closed, or from a browser since restarted -- or open and owned by
/// somebody else, which a caller cannot tell apart and must not be able to.
/// A lane sees only its own tabs (ticket 040), so a tab id it was never given
/// has to be indistinguishable from one that does not exist; naming the
/// difference would leak the fact that another lane is holding something.
///
/// The detail used to list every open tab in the browser. Under lanes that is
/// both a leak and useless advice, since none of those ids would be usable.
/// </summary>
public sealed class TabNotFoundException(string tab, string lane, IReadOnlyList<string> openTabs)
    : PassengerException(ErrorCode.TabNotFound, $"no tab {tab} in lane {lane}",
                         openTabs.Count > 0
                             ? "open in this lane: " + string.Join(", ", openTabs)
                             : "this lane has no tabs")
{
    public string Tab { get; } = tab;
    public string Lane { get; } = lane;
}

/// <summary>
/// The lane a call named does not exist, or its clock ran out.
///
/// Not distinguished from "expired", deliberately: a lane whose TTL passed
/// has had its tabs closed, so there is nothing left for the caller to do
/// with the id either way. Both answers are "open a new one".
/// </summary>
public sealed class LaneNotFoundException(string lane)
    : PassengerException(ErrorCode.LaneNotFound, $"no lane {lane}",
                         "it expired, or never existed; open one with openLane")
{
    public string Lane { get; } = lane;
}
