"""Structural domain errors.

Core modules raise these; only the CLI boundary decides what a failure looks
like on a terminal. Codes are stable so callers can branch on them without
matching English.
"""
from enum import Enum


class ErrorCode(str, Enum):
    DAEMON_NOT_RUNNING = "DAEMON_NOT_RUNNING"
    DAEMON_START_FAILED = "DAEMON_START_FAILED"
    PORT_IN_USE = "PORT_IN_USE"
    CHROME_NOT_FOUND = "CHROME_NOT_FOUND"
    UNKNOWN_WINDOW_BACKEND = "UNKNOWN_WINDOW_BACKEND"
    NO_PRESENTER = "NO_PRESENTER"
    PAGE_BLOCKED = "PAGE_BLOCKED"
    HANDOFF_TIMEOUT = "HANDOFF_TIMEOUT"
    SIGNATURE_NOT_FOUND = "SIGNATURE_NOT_FOUND"
    REGISTRY_CORRUPT = "REGISTRY_CORRUPT"


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
