"""Imperative shell: serving the page a human takes the browser over in.

Two roots and nothing else: the viewer page that ships with this package, and
noVNC's own modules, which are read from wherever the packaging put them. A
general-purpose static server over one merged directory would have been less
code, but it would also have to be pointed at a directory containing both --
and building that means copying noVNC out of the store at runtime.

The process is detached and outlives the command that started it, the same way
cage and wayvnc do, because `show` returns while the window stays open.
"""
import http.server
import os
import socket
import subprocess
import sys
from pathlib import Path

from .config import settings

PAGE = Path(__file__).parent / "web" / "viewer.html"
_NOVNC_CANDIDATES = ("/usr/share/webapps/novnc", "/usr/share/novnc",
                     "/usr/local/share/novnc")


def novnc_root() -> Path | None:
    """Where noVNC's modules live, or None if this machine has none.

    PASSENGER_NOVNC first, which is what the flake sets to a store path
    holding just the static files; the well-known distribution paths after it,
    so a system-installed noVNC works without configuration.
    """
    if settings.novnc_dir is not None:
        root = Path(settings.novnc_dir)
        return root if (root / "core" / "rfb.js").exists() else None
    for candidate in _NOVNC_CANDIDATES:
        root = Path(candidate)
        if (root / "core" / "rfb.js").exists():
            return root
    return None


class Handler(http.server.SimpleHTTPRequestHandler):
    """Serves the viewer page at / and noVNC's modules under /novnc/."""

    root: Path

    def translate_path(self, path: str) -> str:
        """Map a request to a file, or to nothing at all.

        Deliberately not the inherited behaviour, which serves the whole
        working directory: this process exists to hand out two things, and a
        static server that will read any file it can reach is not something to
        leave listening on a socket, however local.
        """
        clean = path.split("?", 1)[0].split("#", 1)[0]
        if clean in ("/", "/index.html"):
            return str(PAGE)
        if clean.startswith("/novnc/"):
            # posixpath-style resolution, then a containment check: `..` in a
            # request must not walk out of the noVNC tree.
            target = (self.root / clean[len("/novnc/"):]).resolve()
            if target.is_relative_to(self.root.resolve()):
                return str(target)
        return ""

    def log_message(self, format: str, *args: object) -> None:
        """Quiet: this runs detached, and its stdout goes nowhere useful."""
        return None


def serve(port: int, root: Path) -> None:
    Handler.root = root
    with http.server.ThreadingHTTPServer((settings.vnc_host, port),
                                         Handler) as httpd:
        httpd.serve_forever()


def listening(port: int) -> bool:
    """Is something already serving on that port?"""
    with socket.socket() as probe:
        probe.settimeout(0.3)
        return probe.connect_ex((settings.vnc_host, port)) == 0


def ensure(port: int) -> bool:
    """Start the server unless it is already up. False if it cannot be.

    Started as a detached child rather than a thread because the CLI process
    exits as soon as `show` has returned, and the window it opened needs the
    page to keep being served for as long as it is open.
    """
    if listening(port):
        return True
    if novnc_root() is None:
        return False
    subprocess.Popen([sys.executable, "-m", "ab.webserve", str(port)],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
    for _ in range(20):
        if listening(port):
            return True
        _sleep()
    return False


def _sleep() -> None:
    import time
    time.sleep(0.1)


def main() -> None:
    root = novnc_root()
    if root is None:
        raise SystemExit("no noVNC installation found; set PASSENGER_NOVNC")
    port = int(sys.argv[1]) if len(sys.argv) > 1 else settings.novnc_port
    os.chdir("/")
    serve(port, root)


if __name__ == "__main__":
    main()
