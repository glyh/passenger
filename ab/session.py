"""Imperative shell: which cage/wayvnc/viewer processes are *ours*.

Every process this tool starts is nested one inside another -- cage holds
wayvnc and Chrome, and a viewer connects to that wayvnc from outside. Nothing
in the process table says which of them belong together, so this module keeps
the one record that does.

Without it the correlation was guessed by name, and both directions of the
guess were wrong. A second cage session inherited the first one's hardcoded
VNC port, so its wayvnc lost the bind and died while the *stale* one kept
serving an empty compositor -- a viewer that connects and shows black. In the
other direction `pkill -x cage` and a `pkill -x` on the viewer's binary reached
every such process on the machine, so this tool tore down sessions and remote
desktops that were never its own.

The record is written by the session script itself, from inside cage, because
that is the only place that can observe what actually came up: the display it
got, and the pids of the processes cage really started.
"""
import os
import signal
import socket
import time
from pathlib import Path

from pydantic import BaseModel, Field

from .config import STATE_DIR, settings

SESSION_FILE = STATE_DIR / "session.env"
VIEWER_FILE = STATE_DIR / "viewer.pid"
_PORT_SCAN = 64
_EXIT_POLLS = 20
_KILL_POLLS = 20
_POLL_INTERVAL_S = 0.1


class NestedSession(BaseModel, frozen=True):
    """One live cage session, as reported from inside it."""

    cage_pid: int
    chrome_pid: int
    vnc_pid: int
    vnc_host: str
    vnc_port: int = Field(ge=1, le=65535)
    ctl_socket: Path
    wayland_display: str

    @property
    def alive(self) -> bool:
        """Chrome is the session: cage exists only to hold it.

        Keyed on Chrome rather than on cage because cage outliving a dead
        Chrome is exactly the stale state this record has to detect -- that is
        the shape the black screen came in.
        """
        return _alive(self.chrome_pid)


def _alive(pid: int) -> bool:
    """Is this pid a running process?

    A zombie does not count. Chrome dying inside cage leaves an unreaped child
    whose pid still answers signal 0, so a liveness check built on os.kill
    alone reports a dead session as live -- which is the state that had a
    viewer showing a black screen with everything claiming to be fine.
    """
    try:
        stat = Path(f"/proc/{pid}/stat").read_text()
    except (FileNotFoundError, ProcessLookupError):
        return False
    except PermissionError:
        return True  # exists, owned by someone else
    # Field 3 is the state code, after the comm field, which may itself
    # contain spaces or brackets -- so split from the last ')' rather than
    # tokenising the whole line.
    _, _, rest = stat.rpartition(")")
    return rest.split()[0] != "Z" if rest.split() else False


def _parse(text: str) -> dict[str, str]:
    pairs = (line.split("=", 1) for line in text.splitlines() if "=" in line)
    return {key: value for key, value in pairs}


def current() -> NestedSession | None:
    """The recorded session, or None if there is no readable one.

    A malformed or half-written record is treated as absent rather than
    raising: the caller's next move is to start a fresh session either way.
    """
    try:
        return NestedSession.model_validate(_parse(SESSION_FILE.read_text()))
    except Exception:
        return None


def live() -> NestedSession | None:
    session = current()
    return session if session is not None and session.alive else None


def free_port() -> int:
    """First free port at or above the configured one.

    Scanned rather than fixed so a second session -- or anyone else's wayvnc --
    cannot silently take the port this one is about to advertise.
    """
    for port in range(settings.vnc_port, settings.vnc_port + _PORT_SCAN):
        with socket.socket() as probe:
            if probe.connect_ex((settings.vnc_host, port)) != 0:
                return port
    return settings.vnc_port


def ctl_socket(port: int) -> Path:
    """Per-port control socket.

    wayvnc refuses to start when another instance holds the default one, which
    is how the second session lost its VNC server without anything reporting it.
    """
    return STATE_DIR / f"wayvnc-{port}.sock"


def reap_stale() -> str | None:
    """Tear down a recorded session whose Chrome is gone. Returns what it killed.

    Called before starting a new one so the dead session cannot keep holding
    the VNC port that the new session needs to advertise.
    """
    session = current()
    if session is None or session.alive:
        return None
    survived = _stop_all(session)
    reaped = f"reaped stale session on :{session.vnc_port}"
    return f"{reaped}; {survived}" if survived else reaped


def teardown() -> str | None:
    """Stop only the processes this record names. Returns what would not go."""
    session = current()
    if session is None:
        return None
    return _stop_all(session)


def _stop_all(session: NestedSession) -> str | None:
    """Stop a session's processes. Returns a note if any of them survived.

    Waited on rather than fired and forgotten: SIGTERM is asynchronous, so a
    session started immediately afterwards would still find the old listener
    holding the port and quietly claim a different one, drifting upward on
    every restart.

    The wait used to end in a shrug -- the budget ran out and the record was
    unlinked regardless, which is that same drift with the record that names
    the surviving pid deleted, so `reap_stale` could not clean up after it
    either. SIGTERM is now escalated, and the record is kept in the one case
    where even that fails, because an unowned listener is the worse half of
    the bug.
    """
    # Deduplicated so a record that names one process twice cannot report it
    # twice in the note.
    pids = list(dict.fromkeys((session.vnc_pid, session.cage_pid)))
    for pid in pids:
        _terminate(pid)
    survivors = _wait_for_exit(pids, _EXIT_POLLS)
    if not survivors:
        _forget(session)
        return None
    for pid in survivors:
        _kill(pid)
    survivors = _wait_for_exit(survivors, _KILL_POLLS)
    if not survivors:
        _forget(session)
        return None
    # Deliberately keeps the record, and with it the control socket the
    # survivor may still be serving: it is the only thing that ties this port
    # to a session anyone can name, and `reap_stale` reads it on the next run.
    return (f"pid {', '.join(str(pid) for pid in survivors)} survived SIGKILL; "
            f":{session.vnc_port} is still held, session record kept")


def _forget(session: NestedSession) -> None:
    """Drop the per-port state, now that nothing is left to own it."""
    session.ctl_socket.unlink(missing_ok=True)
    SESSION_FILE.unlink(missing_ok=True)


def _wait_for_exit(pids: list[int], polls: int) -> list[int]:
    """Poll until every pid is gone, and report those that are not."""
    for _ in range(polls):
        if not any(_alive(pid) for pid in pids):
            return []
        time.sleep(_POLL_INTERVAL_S)
    return [pid for pid in pids if _alive(pid)]


def _kill(pid: int) -> None:
    try:
        os.kill(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        return


def _terminate(pid: int) -> None:
    try:
        os.kill(pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return


def pids_running(fragment: str) -> list[int]:
    """Pids whose command line contains `fragment`.

    Reads /proc directly rather than shelling out to pgrep: the match is the
    security-relevant part of stopping the right processes, and doing it here
    makes it an ordinary function -- inspectable, and testable without
    spawning anything.
    """
    found: list[int] = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            cmdline = (entry / "cmdline").read_bytes()
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue  # exited between listing and reading
        if fragment.encode() in cmdline:
            found.append(int(entry.name))
    return found


def terminate(pid: int) -> None:
    """SIGTERM one process, tolerating its having already gone."""
    _terminate(pid)


def record_viewer(pid: int) -> None:
    VIEWER_FILE.write_text(str(pid))


def viewer_pid() -> int | None:
    """The viewer this tool spawned, if it is still running.

    Checked by pid and not by name so that a VNC client the user opened for
    something else is never mistaken for ours -- in either direction.
    """
    try:
        pid = int(VIEWER_FILE.read_text().strip())
    except Exception:
        return None
    return pid if _alive(pid) else None


def clear_viewer() -> None:
    VIEWER_FILE.unlink(missing_ok=True)
