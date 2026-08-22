"""Chrome daemon lifecycle + CDP attach.

We launch Chrome ourselves rather than using launch_persistent_context so the
window outlives any single command: you solve a challenge once, and every later
fetch reuses that same warm, logged-in session.

Launch args are deliberately minimal. Every extra flag is a way to look unlike a
normal Chrome start, and --enable-automation (the flag that actually sets
navigator.webdriver) is simply never passed.
"""
import os
import shutil
import socket
import subprocess
import time
import urllib.request

from patchright.sync_api import sync_playwright

from . import window
from .config import CDP_PORT, CDP_URL, CHROME_BIN, PROFILE_DIR


def is_up() -> bool:
    try:
        with urllib.request.urlopen(f"{CDP_URL}/json/version", timeout=1) as r:
            return r.status == 200
    except Exception:
        return False


def _port_taken() -> bool:
    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", CDP_PORT)) == 0


def start(detach: bool = True, hidden: bool = True) -> None:
    if is_up():
        print(f"already running on {CDP_URL}")
        return
    if _port_taken():
        raise SystemExit(f"port {CDP_PORT} is in use by something that isn't our Chrome")
    if not shutil.which(CHROME_BIN):
        raise SystemExit(f"{CHROME_BIN} not found on PATH")

    PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    argv = [
        CHROME_BIN,
        f"--remote-debugging-port={CDP_PORT}",
        f"--user-data-dir={PROFILE_DIR}",
        "--no-first-run",
        "--no-default-browser-check",
    ]
    env = None
    if hidden:
        window.install_rules()
        routed = window.can_hide()
        argv.append(f"--class={window.WM_CLASS}")
        if routed:
            # Off-screen windows get their timers throttled, which stalls the
            # very challenge scripts we need to run. None of these flags are
            # visible to page JS.
            argv += ["--disable-background-timer-throttling",
                     "--disable-backgrounding-occluded-windows",
                     "--disable-renderer-backgrounding"]
        else:
            print("note: no window backend available; window will stay visible")
    argv.append("about:blank")
    if hidden:
        argv, extra_env = window.wrap_launch(argv)
        if extra_env:
            env = {**os.environ, **extra_env}
    subprocess.Popen(
        argv,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=detach,
    )
    for _ in range(60):
        if is_up():
            state = "hidden" if hidden else "visible"
            print(f"chrome up on {CDP_URL} [{state}] (profile: {PROFILE_DIR})")
            return
        time.sleep(0.5)
    raise SystemExit("chrome did not expose CDP in time")


class Session:
    """Attaches patchright to the running Chrome and hands back a page."""

    def __enter__(self):
        if not is_up():
            raise SystemExit("browser not running -- start it with: agent-browser serve")
        self._pw = sync_playwright().start()
        self.browser = self._pw.chromium.connect_over_cdp(CDP_URL)
        self.context = self.browser.contexts[0]
        return self

    def page(self, reuse: bool = True):
        """Reuse a blank tab if one is lying around, else open a new one."""
        if reuse:
            for p in self.context.pages:
                if p.url in ("about:blank", "chrome://newtab/"):
                    return p
        return self.context.new_page()

    def __exit__(self, *exc):
        # Detach only. Closing the browser here would kill the daemon and throw
        # away the session we went to the trouble of warming up.
        try:
            self.browser.close()
        finally:
            self._pw.stop()


def stop() -> None:
    subprocess.run(["pkill", "-f", "--", f"--user-data-dir={PROFILE_DIR}"],
                   check=False)
    subprocess.run(["pkill", "-x", "cage"], check=False)
    print("stopped")
