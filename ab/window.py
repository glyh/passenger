"""Hide the agent's Chrome window until it's actually needed.

Deliberately NOT done by going headless: headless changes the fingerprint (no
GPU, software WebGL, no window) and makes human handoff impossible. The window
stays fully real -- it's just parked somewhere you aren't looking.

There is no standard Wayland protocol for this, so backends are pluggable and
auto-detected. Override with AGENT_BROWSER_WM=hyprland|wlrctl|none.

  nested    Chrome runs inside its own headless cage compositor; the host
            never sees a window at all. Portable across every compositor and
            survives switching -- "show" attaches a VNC viewer. Needs
            cage + wayvnc + a VNC client. This is the default when available.
  hyprland  special workspace (LEGACY: Hyprland <=0.55 only -- 0.56 replaced
            hyprctl dispatch with a Lua API and this no longer works)
  wlrctl    wlr-foreign-toplevel minimize          (wlroots family: sway,
            river, niri, labwc, wayfire, Hyprland; NOT GNOME/KDE)
  none      no-op; the window simply stays visible

For a backend that survives switching to *any* compositor, see docs: run Chrome
inside its own nested headless compositor and view it over VNC on demand.
"""
import os
import shutil
import subprocess
import time

from .config import STATE_DIR

VNC_HOST = os.environ.get("AGENT_BROWSER_VNC_HOST", "127.0.0.1")
VNC_PORT = os.environ.get("AGENT_BROWSER_VNC_PORT", "5900")
SESSION_SH = STATE_DIR / "cage-session.sh"

WM_CLASS = "agent-browser"
SPECIAL_WS = "agentbrowser"


def _run(*args) -> str:
    return subprocess.run(args, capture_output=True, text=True,
                          check=False).stdout.strip()


class _Hyprland:
    name = "hyprland"

    @staticmethod
    def available() -> bool:
        return bool(shutil.which("hyprctl")) and "Hyprland" in os.environ.get(
            "XDG_CURRENT_DESKTOP", "")

    @staticmethod
    def install_rules() -> bool:
        _run("hyprctl", "keyword", "windowrulev2",
             f"workspace special:{SPECIAL_WS} silent,class:^({WM_CLASS})$")
        return True

    @staticmethod
    def visible() -> bool:
        return f"special:{SPECIAL_WS}" in _run("hyprctl", "activeworkspace")

    @staticmethod
    def set_visible(v: bool) -> None:
        if _Hyprland.visible() != v:
            _run("hyprctl", "dispatch", "togglespecialworkspace", SPECIAL_WS)


class _Wlrctl:
    """Portable across wlroots compositors, but minimize is advisory: some
    compositors implement it as a no-op, so treat success as best-effort."""
    name = "wlrctl"

    @staticmethod
    def available() -> bool:
        return bool(shutil.which("wlrctl"))

    @staticmethod
    def install_rules() -> bool:
        return False  # nothing to pre-register; we act on the toplevel directly

    @staticmethod
    def visible() -> bool:
        return WM_CLASS in _run("wlrctl", "toplevel", "list")

    @staticmethod
    def set_visible(v: bool) -> None:
        action = "focus" if v else "minimize"
        _run("wlrctl", "toplevel", action, f"app_id:{WM_CLASS}")


class _NoOp:
    name = "none"
    available = staticmethod(lambda: True)
    install_rules = staticmethod(lambda: False)
    visible = staticmethod(lambda: True)
    set_visible = staticmethod(lambda v: None)


class _Nested:
    """Chrome inside its own cage compositor, viewed over VNC on demand.

    The host compositor is not involved, so nothing here breaks when you
    switch compositors -- or when one of them rewrites its IPC.
    """
    name = "nested"
    VIEWERS = ("wlvncc", "vncviewer", "gvncviewer", "remmina")

    @staticmethod
    def available() -> bool:
        return bool(shutil.which("cage") and shutil.which("wayvnc"))

    @staticmethod
    def viewer() -> str | None:
        return next((v for v in _Nested.VIEWERS if shutil.which(v)), None)

    @staticmethod
    def wrap(argv: list) -> list:
        """Build the cage command that hosts Chrome + a VNC server."""
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        quoted = " ".join(f"'{a}'" for a in argv)
        SESSION_SH.write_text(
            "#!/bin/sh\n"
            f"wayvnc {VNC_HOST} {VNC_PORT} &\n"
            f"exec {quoted}\n")
        SESSION_SH.chmod(0o755)
        return ["cage", "--", str(SESSION_SH)]

    @staticmethod
    def env() -> dict:
        # Headless wlroots backend: no host compositor, but the GPU render node
        # is still used, so WebGL keeps reporting the real adapter.
        return {"WLR_BACKENDS": "headless", "WLR_LIBINPUT_NO_DEVICES": "1"}

    @staticmethod
    def install_rules() -> bool:
        return True

    @staticmethod
    def visible() -> bool:
        # -x matches the process NAME exactly. -f would match any command line
        # merely mentioning a viewer -- including the shell that called us.
        return any(subprocess.run(["pgrep", "-x", v], capture_output=True)
                   .returncode == 0 for v in _Nested.VIEWERS)

    @staticmethod
    def set_visible(v: bool) -> None:
        if v:
            if _Nested.visible():
                return
            viewer = _Nested.viewer()
            if not viewer:
                print(f"no VNC client found; connect manually to "
                      f"{VNC_HOST}:{VNC_PORT}")
                return
            # host::port, not host:port -- a single colon means an X display
            # number, so :5900 would be resolved as port 5900+5900.
            args = ([VNC_HOST, VNC_PORT] if viewer == "wlvncc"
                    else [f"{VNC_HOST}::{VNC_PORT}"])
            subprocess.Popen([viewer, *args], stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
            for _ in range(10):
                time.sleep(0.5)
                if _Nested.visible():
                    return
            print(f"viewer did not connect; try: {viewer} {' '.join(args)}")
        else:
            for vw in _Nested.VIEWERS:
                subprocess.run(["pkill", "-x", vw], check=False)


_BACKENDS = {b.name: b for b in (_Nested, _Hyprland, _Wlrctl, _NoOp)}


def _pick():
    forced = os.environ.get("AGENT_BROWSER_WM")
    if forced:
        b = _BACKENDS.get(forced)
        if b is None:
            raise SystemExit(f"unknown AGENT_BROWSER_WM={forced}; "
                             f"choose from {', '.join(_BACKENDS)}")
        return b
    for b in (_Nested, _Wlrctl, _NoOp):
        if b.available():
            return b
    return _NoOp


def backend() -> str:
    return _pick().name


def can_hide() -> bool:
    return _pick() is not _NoOp


def install_rules() -> bool:
    return _pick().install_rules()


def _visible() -> bool:
    return _pick().visible()


def show() -> bool:
    _pick().set_visible(True)
    return can_hide()


def hide() -> bool:
    _pick().set_visible(False)
    return can_hide()


def wrap_launch(argv: list) -> tuple[list, dict]:
    """Let the backend rewrite the Chrome command line and environment."""
    b = _pick()
    if hasattr(b, "wrap"):
        return b.wrap(argv), b.env()
    return argv, {}
