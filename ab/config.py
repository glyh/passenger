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
    min_content_words: int = Field(default=80, ge=0)
    handoff_timeout_s: int = Field(default=300, ge=1)
    vnc_host: str = "127.0.0.1"
    vnc_port: int = Field(default=5900, ge=1, le=65535)
    # Unset means "fit the output to whoever is looking"; setting it pins the
    # size, which is the only lever on a compositor the probes cannot read.
    vnc_size: str | None = None
    vnc_scale: float | None = Field(default=None, gt=0)
    geometry_cmd: str | None = None
    novnc_port: int = Field(default=6080, ge=1, le=65535)
    presenter: PresenterName | None = None
    webhook_url: str | None = None
    default_extract_mode: ExtractMode = ExtractMode.AUTO

    @classmethod
    def from_env(cls) -> "Settings":
        raw = {
            "state_dir": os.environ.get("AGENT_BROWSER_STATE"),
            "cdp_port": os.environ.get("AGENT_BROWSER_PORT"),
            "chrome_binary": os.environ.get("AGENT_BROWSER_CHROME"),
            "min_content_words": os.environ.get("AGENT_BROWSER_MIN_WORDS"),
            "handoff_timeout_s": os.environ.get("AGENT_BROWSER_HANDOFF_TIMEOUT"),
            "vnc_host": os.environ.get("AGENT_BROWSER_VNC_HOST"),
            "vnc_port": os.environ.get("AGENT_BROWSER_VNC_PORT"),
            "vnc_size": os.environ.get("AGENT_BROWSER_VNC_SIZE"),
            "vnc_scale": os.environ.get("AGENT_BROWSER_VNC_SCALE"),
            "geometry_cmd": os.environ.get("AGENT_BROWSER_GEOMETRY_CMD"),
            "novnc_port": os.environ.get("AGENT_BROWSER_NOVNC_PORT"),
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
    def signatures_file(self) -> Path:
        return self.state_dir / "signatures.json"

    @property
    def reports_dir(self) -> Path:
        return self.state_dir / "reports"

    @property
    def cdp_url(self) -> str:
        return f"http://127.0.0.1:{self.cdp_port}"

    @property
    def novnc_url(self) -> str:
        return f"http://{self.vnc_host}:{self.novnc_port}/vnc.html"


settings = Settings.from_env()

# Aliases so call sites read as plain names rather than settings.x everywhere.
STATE_DIR = settings.state_dir
PROFILE_DIR = settings.profile_dir
SIGNATURES_FILE = settings.signatures_file
REPORTS_DIR = settings.reports_dir
CDP_PORT = settings.cdp_port
CDP_URL = settings.cdp_url
CHROME_BIN = settings.chrome_binary
MIN_CONTENT_WORDS = settings.min_content_words
HANDOFF_TIMEOUT_S = settings.handoff_timeout_s
