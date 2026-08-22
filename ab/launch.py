"""Imperative shell: how Chrome is launched so that it starts out hidden.

Deliberately NOT headless: headless changes the fingerprint (no GPU, software
WebGL, no window) and makes human handoff impossible. The window stays fully
real -- it is just parked somewhere you aren't looking.

There is no standard Wayland protocol for a window to hide itself, and the
compositor-specific ways of doing it are unportable and prone to breaking, so
there is exactly one real mechanism here plus a null object for when its
dependencies are missing. Override the choice with AGENT_BROWSER_WM.

Showing the browser to a human is a separate concern -- see present.py.
"""
import os
import shutil
import subprocess
from typing import Protocol, assert_never, runtime_checkable

from .config import STATE_DIR, settings
from .errors import ErrorCode, WindowError
from .models import BackendName, LaunchPlan

WM_CLASS = "agent-browser"
SESSION_SH = STATE_DIR / "cage-session.sh"


@runtime_checkable
class WindowBackend(Protocol):
    """What every launch mechanism must be able to do."""

    name: BackendName

    def available(self) -> bool: ...
    def prepare(self) -> None: ...
    def plan(self, argv: tuple[str, ...]) -> LaunchPlan: ...


def _run(*args: str) -> str:
    return subprocess.run(args, capture_output=True, text=True,
                          check=False).stdout.strip()


class NestedBackend:
    """Chrome inside its own cage compositor, viewed over VNC on demand.

    The host compositor is not involved, so nothing here breaks when you switch
    compositors -- or when one of them rewrites the IPC a backend depended on.
    """

    name = BackendName.NESTED

    def available(self) -> bool:
        return bool(shutil.which("cage")) and bool(shutil.which("wayvnc"))

    def prepare(self) -> None:
        return None

    def plan(self, argv: tuple[str, ...]) -> LaunchPlan:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        quoted = " ".join(f"'{arg}'" for arg in argv)
        SESSION_SH.write_text(
            f"#!/bin/sh\nwayvnc {settings.vnc_host} {settings.vnc_port} &\n"
            f"exec {quoted}\n")
        SESSION_SH.chmod(0o755)
        # Headless wlroots still renders through the GPU render node, so WebGL
        # keeps reporting the real adapter.
        return LaunchPlan(argv=("cage", "--", str(SESSION_SH)),
                          env={"WLR_BACKENDS": "headless",
                               "WLR_LIBINPUT_NO_DEVICES": "1"})


class NoOpBackend:
    """No mechanism available; the window simply stays visible."""

    name = BackendName.NONE

    def available(self) -> bool:
        return True

    def prepare(self) -> None:
        return None

    def plan(self, argv: tuple[str, ...]) -> LaunchPlan:
        return LaunchPlan(argv=argv)



def _build(name: BackendName) -> WindowBackend:
    match name:
        case BackendName.NESTED:
            return NestedBackend()
        case BackendName.NONE:
            return NoOpBackend()
        case _ as unreachable:
            assert_never(unreachable)


_AUTO_ORDER = (BackendName.NESTED, BackendName.NONE)


def select() -> WindowBackend:
    forced = os.environ.get("AGENT_BROWSER_WM")
    if forced is not None:
        try:
            return _build(BackendName(forced))
        except ValueError as exc:
            raise WindowError(
                ErrorCode.UNKNOWN_WINDOW_BACKEND,
                f"unknown backend {forced!r}",
                detail=", ".join(b.value for b in BackendName)) from exc
    for name in _AUTO_ORDER:
        backend = _build(name)
        if backend.available():
            return backend
    return NoOpBackend()
