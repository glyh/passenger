"""Imperative shell: putting the hidden browser in front of a human.

Separate from how Chrome is launched. The VNC server is always running inside
the nested compositor; presenting just means giving someone a way to look at
it, and that differs by where the tool is deployed:

  local  spawn a VNC client on this machine
  web    hand back a noVNC URL to open in any browser -- the only option that
         works from a container without a client installed on the host
  none   nothing can show it; say so rather than pretending
"""
import shutil
import subprocess
import time
from typing import Protocol, assert_never, runtime_checkable

from .config import settings
from .errors import ErrorCode, WindowError
from .models import PresenterName

VIEWERS = ("wlvncc", "vncviewer", "gvncviewer", "remmina")
_CONNECT_POLLS = 10
_POLL_INTERVAL_S = 0.5


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
        # -x matches the process NAME exactly. -f would match any command line
        # merely mentioning a viewer -- including the shell that called us.
        return any(subprocess.run(["pgrep", "-x", v], capture_output=True)
                   .returncode == 0 for v in VIEWERS)

    def present(self) -> str:
        if self.presented():
            return "viewer already open"
        viewer = self.viewer()
        if viewer is None:
            raise WindowError(ErrorCode.NO_PRESENTER, "no VNC client installed",
                              detail=self._manual_hint())
        # host::port, not host:port -- a single colon means an X display
        # number, so :5900 would be resolved as port 5900+5900.
        args = ([settings.vnc_host, str(settings.vnc_port)] if viewer == "wlvncc"
                else [f"{settings.vnc_host}::{settings.vnc_port}"])
        subprocess.Popen([viewer, *args], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
        for _ in range(_CONNECT_POLLS):
            time.sleep(_POLL_INTERVAL_S)
            if self.presented():
                return f"opened {viewer}"
        raise WindowError(ErrorCode.NO_PRESENTER, "VNC viewer did not connect",
                          detail=f"{viewer} {' '.join(args)}")

    def dismiss(self) -> None:
        for viewer in VIEWERS:
            subprocess.run(["pkill", "-x", viewer], check=False)

    def _manual_hint(self) -> str:
        return f"connect manually to {settings.vnc_host}:{settings.vnc_port}"


class WebPresenter:
    """Hand back a noVNC URL.

    Whether a human actually opened it is unknowable from here, so presented()
    stays False and dismiss() does nothing -- better than inventing a state we
    cannot observe.
    """

    name = PresenterName.WEB

    def available(self) -> bool:
        return True

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
        return "no way to display the browser on this host"

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
    """Explicit choice wins; otherwise a local client, else the web URL."""
    if settings.presenter is not None:
        return _build(settings.presenter)
    local = LocalViewerPresenter()
    if local.available():
        return local
    return WebPresenter()
