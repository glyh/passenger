"""Imperative shell: Chrome daemon lifecycle and CDP attach.

Chrome is launched here rather than through launch_persistent_context so the
window outlives any single command: you solve a challenge once, and every later
fetch reuses that same warm, logged-in session.

Launch args are deliberately minimal. Every extra flag is a way to look unlike
a normal Chrome start, and --enable-automation (the flag that actually sets
navigator.webdriver) is simply never passed.
"""
import os
import shutil
import socket
import subprocess
import time
import urllib.request
from types import TracebackType
from typing import Any

from patchright.sync_api import Error as PlaywrightError
from patchright.sync_api import TimeoutError as PlaywrightTimeout
from patchright.sync_api import sync_playwright

from . import launch, session, targets
from .config import ATTACH_TIMEOUT_S, CDP_PORT, CDP_URL, CHROME_BIN, PROFILE_DIR
from .errors import DaemonError, ErrorCode, TabNotFound
from .models import BackendName

_STARTUP_POLLS = 60
_POLL_INTERVAL_S = 0.5


def is_up() -> bool:
    try:
        with urllib.request.urlopen(f"{CDP_URL}/json/version", timeout=1) as response:
            return bool(response.status == 200)
    except Exception:
        return False


def _port_taken() -> bool:
    with socket.socket() as probe:
        return probe.connect_ex(("127.0.0.1", CDP_PORT)) == 0


def start(detach: bool = True, hidden: bool = True) -> str:
    """Launch the daemon. Returns a one-line description of what came up."""
    if is_up():
        return f"already running on {CDP_URL}"
    if _port_taken():
        raise DaemonError(ErrorCode.PORT_IN_USE,
                          f"port {CDP_PORT} is in use by something else")
    if shutil.which(CHROME_BIN) is None:
        raise DaemonError(ErrorCode.CHROME_NOT_FOUND,
                          f"{CHROME_BIN} not found on PATH")

    # A previous session whose Chrome died leaves cage and wayvnc behind,
    # still holding the VNC port. Left alone, the session starting here cannot
    # claim that port and the stale server keeps answering viewers with the
    # empty compositor it is still attached to.
    session.reap_stale()

    PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    argv: tuple[str, ...] = (
        CHROME_BIN,
        f"--remote-debugging-port={CDP_PORT}",
        f"--user-data-dir={PROFILE_DIR}",
        "--no-first-run",
        "--no-default-browser-check",
    )

    backend = launch.select()
    if hidden and backend.name is BackendName.NONE:
        # Silently launching a visible window would defeat the point of this
        # tool, and the caller would never know. Make them say so explicitly.
        raise DaemonError(
            ErrorCode.CANNOT_HIDE,
            "asked to start hidden, but nothing here can hide a window",
            detail="install cage + wayvnc (or `nix develop`), "
                   "or start it with --visible to accept a visible window")
    if hidden:
        backend.prepare()
        argv += (f"--class={launch.WM_CLASS}",)
        # Off-screen windows get their timers throttled, which stalls the very
        # challenge scripts we need to run. None are visible to page JS.
        argv += ("--disable-background-timer-throttling",
                 "--disable-backgrounding-occluded-windows",
                 "--disable-renderer-backgrounding")
    argv += ("about:blank",)

    plan = backend.plan(argv) if hidden else launch.NoOpBackend().plan(argv)
    subprocess.Popen(
        list(plan.argv),
        env={**os.environ, **plan.env} if plan.env else None,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=detach,
    )
    for _ in range(_STARTUP_POLLS):
        if is_up():
            unfullscreen()
            state = "hidden" if hidden else "visible"
            return f"chrome up on {CDP_URL} [{state}] (profile: {PROFILE_DIR})"
        time.sleep(_POLL_INTERVAL_S)
    raise DaemonError(ErrorCode.DAEMON_START_FAILED,
                      "chrome did not expose CDP in time",
                      detail=" ".join(plan.argv))


def unfullscreen() -> None:
    """Give Chrome its own toolbar back, by taking it out of fullscreen.

    cage is a kiosk compositor: it fullscreens the client it starts, and a
    fullscreen Chrome hides its tab strip and toolbar. Nothing chose that --
    it fell out of the mechanism picked for hiding the window -- and it landed
    on the one moment the window is looked at. A human handed the browser to
    solve a captcha or finish a login could click inside the page and nothing
    else: no address bar to read or type into, no back button out of a
    redirect, no tabs.

    Windowed is also the more ordinary of the two shapes for a real browser to
    be in: a fullscreen window reports outerHeight equal to the screen with no
    browser UI accounting for the difference.

    Cheap and idempotent, so it runs on every start and again before
    every handoff (see present._prepared). When the window was never
    fullscreen -- --visible, or no nested backend -- the state is read and
    nothing is written.
    """
    if not is_up():
        return
    try:
        with Session() as sess:
            page = next(iter(sess.context.pages), None)
            if page is None:
                return  # no target to name a window by; nothing to fix
            target = sess.context.new_cdp_session(page).send("Target.getTargetInfo")
            control = sess.browser.new_browser_cdp_session()
            window = control.send("Browser.getWindowForTarget",
                                  {"targetId": target["targetInfo"]["targetId"]})
            if window["bounds"]["windowState"] != "fullscreen":
                return
            control.send("Browser.setWindowBounds",
                         {"windowId": window["windowId"],
                          "bounds": {"windowState": "normal"}})
    except PlaywrightError:
        # The daemon is up and fetching works; only the toolbar is missing.
        # Raising here would report a working browser as a failed start.
        return


def stop() -> None:
    """Stop this tool's browser, and nothing else.

    Scoped to the recorded session and to our own profile directory. The
    previous `pkill -x cage` matched on the program name, so it also killed
    cage sessions belonging to anyone else on the machine.
    """
    for pid in session.pids_running(f"--user-data-dir={PROFILE_DIR}"):
        session.terminate(pid)
    session.teardown()


class Session:
    """Attaches patchright to the running Chrome and hands back pages."""

    def __enter__(self) -> "Session":
        if not is_up():
            raise DaemonError(ErrorCode.DAEMON_NOT_RUNNING,
                              "browser not running",
                              detail="start it with: agent-browser serve")
        self._playwright = sync_playwright().start()
        self.browser = self._attach()
        self.context = self.browser.contexts[0]
        return self

    def _attach(self) -> Any:
        """Attach -- and if a stuck tab is holding the attach open, free it.

        connect_over_cdp initialises every tab that is already open and waits
        for all of them, and passes no timeout of its own. So one tab left
        mid-navigation used to hang every later call, forever, and every entry
        point into this tool starts with an attach: the whole thing bricked
        until a human found the tab. Measured at 75s and still counting.

        The rescue cannot use patchright, since patchright is what is stuck.
        It goes to the browser process directly instead (see targets.py), and
        stops the pending navigation rather than closing the tab -- whatever
        document that tab already had is usually the one a human was reading.
        """
        try:
            return self._connect()
        except PlaywrightTimeout:
            # A timeout here only abandons the call on this side: the driver
            # carries on attaching, and its half-finished attach is itself part
            # of what holds a tab -- it pauses every request for interception
            # and then never answers. So the driver goes first, then whatever
            # is still stuck is freed, and the retry starts from nothing.
            self._restart_driver()
            stuck = targets.unstick()
            try:
                return self._connect()
            except PlaywrightTimeout as again:
                raise DaemonError(
                    ErrorCode.ATTACH_TIMEOUT,
                    f"could not attach to chrome within {ATTACH_TIMEOUT_S}s, "
                    "twice",
                    detail=(", ".join(page.url for page in stuck) if stuck else
                            "no tab was stuck mid-navigation, so this is "
                            "something else; try: agent-browser stop")) from again

    def _restart_driver(self) -> None:
        try:
            self._playwright.stop()
        except Exception:
            pass  # it is being replaced; how it died does not matter
        self._playwright = sync_playwright().start()

    def _connect(self) -> Any:
        return self._playwright.chromium.connect_over_cdp(
            CDP_URL, timeout=ATTACH_TIMEOUT_S * 1000)

    def page(self, reuse: bool = True) -> Any:
        """Reuse a blank tab if one is lying around, else open a new one."""
        if reuse:
            for existing in self.context.pages:
                if existing.url in ("about:blank", "chrome://newtab/"):
                    return existing
        return self.context.new_page()

    def target_id(self, page: Any) -> str:
        """The tab's CDP id -- the handle a caller holds between calls.

        Not the Playwright Page object, which lives only as long as this
        attach, and not the URL, which changes under a script's feet.
        """
        info: dict[str, Any] = self.context.new_cdp_session(page).send(
            "Target.getTargetInfo")
        return str(info["targetInfo"]["targetId"])

    def page_for(self, tab: str | None) -> Any:
        """The tab a call named, or a blank one when it named none."""
        if tab is None:
            return self.page(reuse=True)
        open_now = {self.target_id(page): page for page in self.context.pages}
        if tab not in open_now:
            # Closed, or from a browser that has restarted since. Either way
            # the caller is holding a handle to something gone, and needs to
            # know which tabs there are rather than a bare failure.
            raise TabNotFound(tab, tuple(open_now))
        return open_now[tab]

    def close_other_tabs(self, keep: Any) -> int:
        """Close every tab except `keep`. Returns how many were closed.

        Chrome exits when its last tab closes, which would take the daemon and
        the warm session with it -- so this is expressed as "keep that one"
        rather than "close all", making it impossible to ask for zero.
        """
        closed = 0
        for page in list(self.context.pages):
            if page is keep:
                continue
            try:
                page.close()
            except Exception:
                continue  # already gone, or mid-navigation
            closed += 1
        return closed

    def __exit__(self, exc_type: type[BaseException] | None,
                 exc: BaseException | None,
                 tb: TracebackType | None) -> None:
        # Detach only. Closing the browser would kill the daemon and throw away
        # the session we went to the trouble of warming up.
        try:
            self.browser.close()
        finally:
            self._playwright.stop()
