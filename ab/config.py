"""Paths and tunables. State lives outside the repo so the profile survives reinstalls."""
import os
from pathlib import Path

STATE_DIR = Path(os.environ.get("AGENT_BROWSER_STATE",
                                Path.home() / ".local/share/agent-browser"))
PROFILE_DIR = STATE_DIR / "chrome-profile"
SIGNATURES_FILE = STATE_DIR / "signatures.json"
REPORTS_DIR = STATE_DIR / "reports"

CDP_PORT = int(os.environ.get("AGENT_BROWSER_PORT", "9222"))
CDP_URL = f"http://127.0.0.1:{CDP_PORT}"
CHROME_BIN = os.environ.get("AGENT_BROWSER_CHROME", "google-chrome-stable")

# A page that extracts to fewer words than this is treated as suspicious even
# when no signature matches -- this is what catches challenge types we've never
# seen before.
MIN_CONTENT_WORDS = int(os.environ.get("AGENT_BROWSER_MIN_WORDS", "80"))
HANDOFF_TIMEOUT_S = int(os.environ.get("AGENT_BROWSER_HANDOFF_TIMEOUT", "300"))
