"""Imperative shell: the environment boundary.

Every AGENT_BROWSER_* variable is read exactly once, here, into a frozen model.
No other module touches os.environ (except window.py's backend override, which
must be read before a backend exists to hold it).
"""
import os
from pathlib import Path

from pydantic import BaseModel, Field

from .models import ExtractMode, PresenterName


class Settings(BaseModel, frozen=True):
    state_dir: Path = Field(default_factory=lambda: Path.home()
                            / ".local/share/agent-browser")
    cdp_port: int = Field(default=9222, ge=1, le=65535)
    chrome_binary: str = "google-chrome-stable"
    handoff_timeout_s: int = Field(default=300, ge=1)
    # How long to wait for an attach before treating the browser as
    # stuck. Attaching initialises every open tab, so this is really a
    # budget for the slowest one.
    attach_timeout_s: int = Field(default=15, ge=1)
    vnc_host: str = "127.0.0.1"
    vnc_port: int = Field(default=5900, ge=1, le=65535)
    # The viewer asks for the framebuffer size it needs, so there is nothing to
    # pin here. The scale it cannot ask for: unset means "match the host
    # screen", and setting it overrides that.
    vnc_scale: float | None = Field(default=None, gt=0)
    novnc_port: int = Field(default=6080, ge=1, le=65535)
    # Where noVNC's modules live. Set by the flake to a store path holding
    # only the static files; unset means "look in the usual system places".
    novnc_dir: str | None = None
    # The browser the viewer window is opened in, which is the host's, not the
    # nested one -- though by default it is the same binary.
    viewer_browser: str | None = None
    presenter: PresenterName | None = None
    webhook_url: str | None = None
    default_extract_mode: ExtractMode = ExtractMode.AUTO

    @classmethod
    def from_env(cls) -> "Settings":
        raw = {
            "state_dir": os.environ.get("AGENT_BROWSER_STATE"),
            "cdp_port": os.environ.get("AGENT_BROWSER_PORT"),
            "chrome_binary": os.environ.get("AGENT_BROWSER_CHROME"),
            "handoff_timeout_s": os.environ.get("AGENT_BROWSER_HANDOFF_TIMEOUT"),
            "attach_timeout_s": os.environ.get("AGENT_BROWSER_ATTACH_TIMEOUT"),
            "vnc_host": os.environ.get("AGENT_BROWSER_VNC_HOST"),
            "vnc_port": os.environ.get("AGENT_BROWSER_VNC_PORT"),
            "vnc_scale": os.environ.get("AGENT_BROWSER_VNC_SCALE"),
            "novnc_port": os.environ.get("AGENT_BROWSER_NOVNC_PORT"),
            "novnc_dir": os.environ.get("AGENT_BROWSER_NOVNC"),
            "viewer_browser": os.environ.get("AGENT_BROWSER_VIEWER"),
            "presenter": os.environ.get("AGENT_BROWSER_PRESENTER"),
            "webhook_url": os.environ.get("AGENT_BROWSER_WEBHOOK"),
            "default_extract_mode": os.environ.get("AGENT_BROWSER_EXTRACT"),
        }
        # Pydantic coerces the strings; unset keys fall back to the defaults.
        return cls.model_validate({k: v for k, v in raw.items() if v is not None})

    @property
    def runtime_dir(self) -> str:
        """Where the Wayland sockets live, for talking to the nested session."""
        return os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")

    @property
    def profile_dir(self) -> Path:
        return self.state_dir / "chrome-profile"

    @property
    def viewer_profile(self) -> Path:
        """A profile of its own for the window the browser is watched in.

        Separate from the user's everyday browser for two reasons. It keeps a
        takeover window out of their session entirely, and it is what makes
        the window ours to close: launched into an already-running Chrome, the
        process we started hands the window over and exits, leaving nothing to
        track or dismiss.
        """
        return self.state_dir / "viewer-profile"

    @property
    def signatures_file(self) -> Path:
        return self.state_dir / "signatures.json"

    @property
    def reports_dir(self) -> Path:
        return self.state_dir / "reports"

    @property
    def cdp_url(self) -> str:
        return f"http://127.0.0.1:{self.cdp_port}"

    @property
    def viewer_url(self) -> str:
        """The page, without the endpoint: that is per-session, so present.py
        appends it from the live record rather than from settings."""
        return f"http://{self.vnc_host}:{self.novnc_port}/"


settings = Settings.from_env()

# Aliases so call sites read as plain names rather than settings.x everywhere.
STATE_DIR = settings.state_dir
PROFILE_DIR = settings.profile_dir
SIGNATURES_FILE = settings.signatures_file
REPORTS_DIR = settings.reports_dir
CDP_PORT = settings.cdp_port
CDP_URL = settings.cdp_url
CHROME_BIN = settings.chrome_binary
HANDOFF_TIMEOUT_S = settings.handoff_timeout_s
ATTACH_TIMEOUT_S = settings.attach_timeout_s
