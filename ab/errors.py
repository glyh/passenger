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
    SIGNATURE_NOT_FOUND = "SIGNATURE_NOT_FOUND"
    REGISTRY_CORRUPT = "REGISTRY_CORRUPT"
    SCRIPT_INVALID = "SCRIPT_INVALID"
    SCRIPT_RAISED = "SCRIPT_RAISED"
    SCRIPT_RETURN_NOT_JSON = "SCRIPT_RETURN_NOT_JSON"
    TAB_NOT_FOUND = "TAB_NOT_FOUND"


class AgentBrowserError(Exception):
    """Base for every failure this tool raises on purpose."""

    def __init__(self, code: ErrorCode, message: str, *,
                 detail: str | None = None) -> None:
        self.code = code
        self.message = message
        self.detail = detail
        super().__init__(f"[{code.value}] {message}")


class DaemonError(AgentBrowserError):
    """The Chrome daemon is missing, unstartable, or contested."""


class WindowError(AgentBrowserError):
    """The window backend could not do what was asked."""


class BlockedError(AgentBrowserError):
    """A page needs a human and we were told not to ask for one."""

    def __init__(self, blocker_name: str, url: str) -> None:
        super().__init__(ErrorCode.PAGE_BLOCKED,
                         f"blocked by {blocker_name}", detail=url)
        self.blocker_name = blocker_name
        self.url = url


class HandoffTimeout(AgentBrowserError):
    def __init__(self, blocker_name: str, seconds: int) -> None:
        super().__init__(ErrorCode.HANDOFF_TIMEOUT,
                         f"no human solved {blocker_name} within {seconds}s")
        self.blocker_name = blocker_name
        self.seconds = seconds


class RegistryError(AgentBrowserError):
    """The learned-signature store is unreadable or lacks a named entry."""


class ScriptError(AgentBrowserError):
    """A caller's script would not compile, raised, or returned a handle."""


class TabNotFound(AgentBrowserError):
    """The tab a call named is gone -- closed, or from a browser since restarted."""

    def __init__(self, tab: str, open_tabs: tuple[str, ...]) -> None:
        super().__init__(ErrorCode.TAB_NOT_FOUND, f"no tab {tab}",
                         detail=("open now: " + ", ".join(open_tabs)
                                 if open_tabs else "no tabs are open"))
        self.tab = tab
