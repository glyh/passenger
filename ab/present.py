"""Imperative shell: putting the hidden browser in front of a human.

Separate from how Chrome is launched. The VNC server is always running inside
the nested compositor; presenting just means giving someone a way to look at
it, and that differs by where the tool is deployed:

  local  spawn a VNC client on this machine
  web    hand back a noVNC URL to open in any browser -- the only option that
         works from a container without a client installed on the host
  none   nothing can show it; say so rather than pretending
"""
import os
import shutil
import signal
import socket
import subprocess
import time
from contextlib import suppress
from typing import Protocol, assert_never, runtime_checkable

from . import geometry, session
from .config import settings
from .errors import ErrorCode, WindowError
from .models import PresenterName

VIEWERS = ("wlvncc", "vncviewer", "gvncviewer", "remmina")
_CONNECT_POLLS = 10
_POLL_INTERVAL_S = 0.5


def endpoint() -> tuple[str, int]:
    """Where the *live* session is listening.

    Read from the session record rather than from settings, because the port a
    session ends up on is claimed when it starts. Pointing a viewer at the
    configured port instead is how a viewer ends up attached to a previous,
    dead session and shows nothing but black.
    """
    live = session.live()
    if live is None:
        return settings.vnc_host, settings.vnc_port
    return live.vnc_host, live.vnc_port


@runtime_checkable
class Presenter(Protocol):
    name: PresenterName

    def available(self) -> bool: ...
    def present(self) -> str: ...
    def dismiss(self) -> None: ...
    def presented(self) -> bool: ...


class LocalViewerPresenter:
    """Spawn a VNC client window on this machine."""

    name = PresenterName.LOCAL

    def viewer(self) -> str | None:
        return next((v for v in VIEWERS if shutil.which(v)), None)

    def available(self) -> bool:
        return self.viewer() is not None

    def presented(self) -> bool:
        """Is *our* viewer open?

        Tracked by the pid we spawned, not by process name. Matching on the
        name meant any VNC client the user had open for something else read as
        "already showing", so a show request returned success having put
        nothing on screen.
        """
        return session.viewer_pid() is not None

    def present(self) -> str:
        live = session.live()
        if self.presented():
            # Re-fitting on a repeat show is the way back to a borderless
            # picture after the window has been moved or resized, since the
            # viewer never asks the server to resize on its own.
            return f"viewer already open{_fitted(live)}"
        viewer = self.viewer()
        if viewer is None:
            raise WindowError(ErrorCode.NO_PRESENTER, "no VNC client installed",
                              detail=self._manual_hint())
        # Refused rather than shown: with no live session there is nothing
        # behind the port, and a viewer opened onto it displays a black
        # rectangle that looks exactly like a broken VNC stack.
        if session.live() is None:
            raise WindowError(ErrorCode.NO_PRESENTER, "no live browser session",
                              detail="start it with: agent-browser serve")
        host, port = endpoint()
        # host::port, not host:port -- a single colon means an X display
        # number, so :5900 would be resolved as port 5900+5900.
        # -n hides wlvncc's own cursor. The server draws the pointer into
        # the frame (--render-cursor), which is what makes it visible at all;
        # without -n the client then draws a second one over the top and you
        # get two pointers moving together.
        args = ([host, str(port), "-n"] if viewer == "wlvncc"
                else [f"{host}::{port}"])
        spawned = subprocess.Popen([viewer, *args], stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL,
                                   start_new_session=True)
        session.record_viewer(spawned.pid)
        for _ in range(_CONNECT_POLLS):
            time.sleep(_POLL_INTERVAL_S)
            if self.presented():
                # Fitted only once the viewer is up: the target is that
                # window's size, so it has to exist to be measured.
                return f"opened {viewer} on {host}:{port}{_fitted(live)}"
        session.clear_viewer()
        raise WindowError(ErrorCode.NO_PRESENTER, "VNC viewer did not connect",
                          detail=f"{viewer} {' '.join(args)}")

    def dismiss(self) -> None:
        """Close only the viewer this tool opened.

        The old `pkill -x` swept up every VNC client on the machine, including
        remote desktops that had nothing to do with this browser.
        """
        pid = session.viewer_pid()
        if pid is not None:
            with suppress(ProcessLookupError, PermissionError):
                os.kill(pid, signal.SIGTERM)
        session.clear_viewer()

    def _manual_hint(self) -> str:
        host, port = endpoint()
        return f"connect manually to {host}:{port}"


def _fitted(live: session.NestedSession | None) -> str:
    """Size the nested output to the viewer, and say so if anything changed."""
    if live is None:
        return ""
    change = geometry.fit(live.wayland_display)
    return "" if change is None else f", output {change}"


class WebPresenter:
    """Hand back a noVNC URL.

    Whether a human actually opened it is unknowable from here, so presented()
    stays False and dismiss() does nothing -- better than inventing a state we
    cannot observe.
    """

    name = PresenterName.WEB

    def available(self) -> bool:
        """Only if something is actually serving noVNC.

        Handing back a URL that answers nothing would be the same silent lie as
        launching a visible window and calling it hidden.
        """
        with socket.socket() as probe:
            probe.settimeout(0.3)
            return probe.connect_ex((settings.vnc_host,
                                     settings.novnc_port)) == 0

    def presented(self) -> bool:
        return False

    def present(self) -> str:
        return f"open {settings.novnc_url} to take over the browser"

    def dismiss(self) -> None:
        return None


class NullPresenter:
    name = PresenterName.NONE

    def available(self) -> bool:
        return True

    def presented(self) -> bool:
        return False

    def present(self) -> str:
        """Say what is actually available rather than just refusing.

        wayvnc is listening whenever the nested compositor is up, so any VNC
        client can still reach it -- from another machine, or a phone.
        """
        host, port = endpoint()
        return ("no viewer installed and no noVNC server; wayvnc is listening "
                f"on {host}:{port} -- point any VNC client at it")

    def dismiss(self) -> None:
        return None


def _build(name: PresenterName) -> Presenter:
    match name:
        case PresenterName.LOCAL:
            return LocalViewerPresenter()
        case PresenterName.WEB:
            return WebPresenter()
        case PresenterName.NONE:
            return NullPresenter()
        case _ as unreachable:
            assert_never(unreachable)


def select() -> Presenter:
    """Explicit choice wins; otherwise the first mechanism that really exists.

    Each candidate is asked whether it is available, including the web one --
    an unconditional fallback would hand back a noVNC URL with nothing serving
    it, which is a worse answer than admitting there is no viewer.
    """
    if settings.presenter is not None:
        return _build(settings.presenter)
    for candidate in (LocalViewerPresenter(), WebPresenter()):
        if candidate.available():
            return candidate
    return NullPresenter()
