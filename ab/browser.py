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

from patchright.sync_api import sync_playwright

from . import launch
from .config import CDP_PORT, CDP_URL, CHROME_BIN, PROFILE_DIR
from .errors import DaemonError, ErrorCode

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

    PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    argv: tuple[str, ...] = (
        CHROME_BIN,
        f"--remote-debugging-port={CDP_PORT}",
        f"--user-data-dir={PROFILE_DIR}",
        "--no-first-run",
        "--no-default-browser-check",
    )

    backend = launch.select()
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
            state = "hidden" if hidden else "visible"
            return f"chrome up on {CDP_URL} [{state}] (profile: {PROFILE_DIR})"
        time.sleep(_POLL_INTERVAL_S)
    raise DaemonError(ErrorCode.DAEMON_START_FAILED,
                      "chrome did not expose CDP in time",
                      detail=" ".join(plan.argv))


def stop() -> None:
    subprocess.run(["pkill", "-f", "--", f"--user-data-dir={PROFILE_DIR}"],
                   check=False)
    subprocess.run(["pkill", "-x", "cage"], check=False)


class Session:
    """Attaches patchright to the running Chrome and hands back pages."""

    def __enter__(self) -> "Session":
        if not is_up():
            raise DaemonError(ErrorCode.DAEMON_NOT_RUNNING,
                              "browser not running",
                              detail="start it with: agent-browser serve")
        self._playwright = sync_playwright().start()
        self.browser = self._playwright.chromium.connect_over_cdp(CDP_URL)
        self.context = self.browser.contexts[0]
        return self

    def page(self, reuse: bool = True) -> Any:
        """Reuse a blank tab if one is lying around, else open a new one."""
        if reuse:
            for existing in self.context.pages:
                if existing.url in ("about:blank", "chrome://newtab/"):
                    return existing
        return self.context.new_page()

    def __exit__(self, exc_type: type[BaseException] | None,
                 exc: BaseException | None,
                 tb: TracebackType | None) -> None:
        # Detach only. Closing the browser would kill the daemon and throw away
        # the session we went to the trouble of warming up.
        try:
            self.browser.close()
        finally:
            self._playwright.stop()
