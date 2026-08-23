"""Structural domain errors.

Core modules raise these; only the CLI boundary decides what a failure looks
like on a terminal. Codes are stable so callers can branch on them without
matching English.
"""
from enum import Enum


class ErrorCode(str, Enum):
    DAEMON_NOT_RUNNING = "DAEMON_NOT_RUNNING"
    DAEMON_START_FAILED = "DAEMON_START_FAILED"
    ATTACH_TIMEOUT = "ATTACH_TIMEOUT"
    PORT_IN_USE = "PORT_IN_USE"
    CHROME_NOT_FOUND = "CHROME_NOT_FOUND"
    UNKNOWN_WINDOW_BACKEND = "UNKNOWN_WINDOW_BACKEND"
    NO_PRESENTER = "NO_PRESENTER"
    CANNOT_HIDE = "CANNOT_HIDE"
    PAGE_BLOCKED = "PAGE_BLOCKED"
    HANDOFF_TIMEOUT = "HANDOFF_TIMEOUT"
    SCRIPT_INVALID = "SCRIPT_INVALID"
    SCRIPT_RAISED = "SCRIPT_RAISED"
    SCRIPT_RETURN_NOT_JSON = "SCRIPT_RETURN_NOT_JSON"
    TAB_NOT_FOUND = "TAB_NOT_FOUND"
    LANE_NOT_FOUND = "LANE_NOT_FOUND"


class PassengerError(Exception):
    """Base for every failure this tool raises on purpose."""

    def __init__(self, code: ErrorCode, message: str, *,
                 detail: str | None = None) -> None:
        self.code = code
        self.message = message
        self.detail = detail
        super().__init__(f"[{code.value}] {message}")


class DaemonError(PassengerError):
    """The Chrome daemon is missing, unstartable, or contested."""


class WindowError(PassengerError):
    """The window backend could not do what was asked."""


class BlockedError(PassengerError):
    """A page needs a human and we were told not to ask for one."""

    def __init__(self, blocker_name: str, url: str) -> None:
        super().__init__(ErrorCode.PAGE_BLOCKED,
                         f"blocked by {blocker_name}", detail=url)
        self.blocker_name = blocker_name
        self.url = url


class HandoffTimeout(PassengerError):
    def __init__(self, blocker_name: str, seconds: int) -> None:
        super().__init__(ErrorCode.HANDOFF_TIMEOUT,
                         f"no human solved {blocker_name} within {seconds}s")
        self.blocker_name = blocker_name
        self.seconds = seconds


class ScriptError(PassengerError):
    """A caller's script would not compile, raised, or returned a handle."""


class TabNotFound(PassengerError):
    """The tab a call named is not in this lane.

    Gone -- closed, or from a browser since restarted -- or open and owned by
    somebody else, which a caller cannot tell apart and must not be able to.
    A lane sees only its own tabs (ticket 040), so a tab id it was never given
    has to be indistinguishable from one that does not exist; naming the
    difference would leak the fact that another lane is holding something.

    The detail used to list every open tab in the browser. Under lanes that is
    both a leak and useless advice, since none of those ids would be usable.
    """

    def __init__(self, tab: str, lane: str, open_tabs: tuple[str, ...]) -> None:
        super().__init__(ErrorCode.TAB_NOT_FOUND, f"no tab {tab} in lane {lane}",
                         detail=("open in this lane: " + ", ".join(open_tabs)
                                 if open_tabs else "this lane has no tabs"))
        self.tab = tab
        self.lane = lane


class LaneNotFound(PassengerError):
    """The lane a call named does not exist, or its clock ran out.

    Not distinguished from "expired", deliberately: a lane whose TTL passed
    has had its tabs closed, so there is nothing left for the caller to do
    with the id either way. Both answers are "open a new one".
    """

    def __init__(self, lane: str) -> None:
        super().__init__(ErrorCode.LANE_NOT_FOUND, f"no lane {lane}",
                         detail="it expired, or never existed; "
                                "open one with open_lane")
        self.lane = lane
