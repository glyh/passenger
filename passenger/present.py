"""Imperative shell: putting the hidden browser in front of a human.

Separate from how Chrome is launched. wayvnc is always running inside the
nested compositor, serving the session over a websocket; presenting just means
giving someone a way to look at it, and that differs by where the tool is
deployed:

  local  open the viewer page in a chromeless window of the host's browser
  web    hand back the URL to open wherever the human actually is -- the only
         option that works from a container with no display of its own
  none   nothing can show it; say so rather than pretending

There is no VNC client here any more. The viewer is a page (passenger/web/viewer.html)
served to the host's own browser, which is both lighter than every native
client that would do -- 1.8 MB of noVNC against 1.2 GiB for the lightest native
one that works -- and the only one of them that gets the size right by itself:
it asks for the framebuffer its window needs and keeps asking as the window
changes. The native client this replaced did the opposite, stretching whatever
it was sent to fill its window and freezing that aspect at connect time, which
is why the picture used to arrive squashed inside black bars.

Opening it in app mode is what makes it read as a window rather than a browser
tab: no tab strip, no address bar, and the page itself is the screen, edge to
edge.
"""
import os
import shutil
import signal
import subprocess
import time
from contextlib import suppress
from typing import Protocol, assert_never, runtime_checkable

from . import browser as browser_mod
from . import geometry, session, webserve
from .config import settings
from .errors import ErrorCode, WindowError
from .models import PresenterName

# Chrome first because it is already this tool's dependency, then the common
# Chromium builds: app mode is a Chromium feature, and a browser without it
# would open a tab with a URL bar around the screen.
BROWSERS = ("google-chrome-stable", "chromium", "chromium-browser",
            "brave-browser", "microsoft-edge-stable")
_OPEN_POLLS = 20
_POLL_INTERVAL_S = 0.25


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


def page_url() -> str:
    """The viewer page, told which session to connect to."""
    host, port = endpoint()
    return f"{settings.viewer_url}?ws={host}:{port}"


@runtime_checkable
class Presenter(Protocol):
    name: PresenterName
    # Whether presented() is a real observation or a standing guess. Only a
    # presenter that can see its own window may be waited on: the human
    # closing the viewer is the one completion signal this tool does not have
    # to infer, and a presenter that always answers False would report it the
    # instant the wait began (ticket 018).
    observes_presence: bool

    def available(self) -> bool: ...
    def present(self) -> str: ...
    def dismiss(self) -> None: ...
    def presented(self) -> bool: ...


def _prepared(live: session.NestedSession | None) -> str:
    """Make the nested session fit to be looked at, and say what changed.

    Two things a human needs that a hidden browser does not. The output takes
    the host screen's density -- only the density: the size belongs to the
    viewer, which asks for it over RFB as soon as it connects and again
    whenever its window changes. And Chrome comes out of the fullscreen cage
    put it in, which is what hid its address bar and back button from the
    person being asked to use them.

    Done here rather than only at startup so that a session started before
    this existed, or one somehow re-fullscreened, is still handed over with
    its controls.
    """
    if live is None:
        return ""
    browser_mod.unfullscreen()
    change = geometry.fit(live.wayland_display)
    return "" if change is None else f", {change}"


class WindowPresenter:
    """Open the viewer page in a chromeless window on this machine."""

    name = PresenterName.LOCAL
    observes_presence = True

    def browser(self) -> str | None:
        candidates = ((settings.viewer_browser,) if settings.viewer_browser
                      else BROWSERS)
        return next((b for b in candidates if shutil.which(b)), None)

    def available(self) -> bool:
        return (self.browser() is not None
                and webserve.novnc_root() is not None)

    def presented(self) -> bool:
        """Is *our* window open?

        Tracked by the pid we spawned, which is only meaningful because the
        window runs on a profile of its own -- see settings.viewer_profile.
        """
        return session.viewer_pid() is not None

    def present(self) -> str:
        live = session.live()
        if self.presented():
            return f"viewer already open{_prepared(live)}"
        browser = self.browser()
        if browser is None:
            raise WindowError(ErrorCode.NO_PRESENTER, "no browser to open",
                              detail=self._manual_hint())
        # Refused rather than shown: with no live session there is nothing
        # behind the port, and a viewer opened onto it shows an empty
        # rectangle that looks exactly like a broken stack.
        if live is None:
            raise WindowError(ErrorCode.NO_PRESENTER, "no live browser session",
                              detail="start it with: passenger serve")
        if not webserve.ensure(settings.novnc_port):
            raise WindowError(ErrorCode.NO_PRESENTER, "cannot serve the viewer",
                              detail="no noVNC found; set PASSENGER_NOVNC")
        prepared = _prepared(live)
        self._open(browser)
        return f"opened {browser} on {page_url()}{prepared}"

    def _open(self, browser: str) -> None:
        """Start the window and wait for it to be up, or say it never was."""
        args = [f"--app={page_url()}",
                f"--user-data-dir={settings.viewer_profile}",
                "--no-first-run", "--no-default-browser-check",
                "--class=passenger-viewer"]
        spawned = subprocess.Popen([browser, *args], stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL,
                                   start_new_session=True)
        session.record_viewer(spawned.pid)
        for _ in range(_OPEN_POLLS):
            time.sleep(_POLL_INTERVAL_S)
            if self.presented():
                return
        session.clear_viewer()
        raise WindowError(ErrorCode.NO_PRESENTER, "viewer window did not open",
                          detail=f"{browser} {' '.join(args)}")

    def dismiss(self) -> None:
        """Close only the window this tool opened.

        The old `pkill -x` swept up every VNC client on the machine, including
        remote desktops that had nothing to do with this browser.
        """
        pid = session.viewer_pid()
        if pid is not None:
            with suppress(ProcessLookupError, PermissionError):
                os.kill(pid, signal.SIGTERM)
        session.clear_viewer()

    def _manual_hint(self) -> str:
        return f"open {page_url()} in any browser"


class LinkPresenter:
    """Hand back the URL for a human to open wherever they are.

    Whether anyone actually opened it is unknowable from here, so presented()
    stays False and dismiss() does nothing -- better than inventing a state we
    cannot observe.
    """

    name = PresenterName.WEB
    observes_presence = False

    def available(self) -> bool:
        """Only if the page can actually be served.

        Handing back a URL that answers nothing would be the same silent lie as
        launching a visible window and calling it hidden.
        """
        return webserve.novnc_root() is not None

    def presented(self) -> bool:
        return False

    def present(self) -> str:
        live = session.live()
        if not webserve.ensure(settings.novnc_port):
            raise WindowError(ErrorCode.NO_PRESENTER, "cannot serve the viewer",
                              detail="no noVNC found; set PASSENGER_NOVNC")
        prepared = _prepared(live)
        return f"open {page_url()} to take over the browser{prepared}"

    def dismiss(self) -> None:
        return None


class NullPresenter:
    name = PresenterName.NONE
    observes_presence = False

    def available(self) -> bool:
        return True

    def presented(self) -> bool:
        return False

    def present(self) -> str:
        """Say what is actually available rather than just refusing.

        wayvnc is listening whenever the nested compositor is up, so a browser
        pointed at any noVNC installation can still reach it -- from another
        machine, or a phone. It speaks websocket rather than raw RFB, though,
        so a native VNC client is not the fallback it used to be.
        """
        host, port = endpoint()
        return ("no viewer: nothing here can serve the noVNC page. wayvnc is "
                f"listening on ws://{host}:{port} -- point a noVNC at it")

    def dismiss(self) -> None:
        return None


def _build(name: PresenterName) -> Presenter:
    match name:
        case PresenterName.LOCAL:
            return WindowPresenter()
        case PresenterName.WEB:
            return LinkPresenter()
        case PresenterName.NONE:
            return NullPresenter()
        case _ as unreachable:
            assert_never(unreachable)


def select() -> Presenter:
    """Explicit choice wins; otherwise the first mechanism that really exists.

    Each candidate is asked whether it is available, including the link one --
    an unconditional fallback would hand back a URL with nothing serving it,
    which is a worse answer than admitting there is no viewer.
    """
    if settings.presenter is not None:
        return _build(settings.presenter)
    for candidate in (WindowPresenter(), LinkPresenter()):
        if candidate.available():
            return candidate
    return NullPresenter()
