"""The session record and its process predicates.

Every test here is a scar. Commit 5275197 fixed a stale `wayvnc` serving a
dead compositor while every status read healthy -- a black screen with nothing
reporting a fault -- and two bugs surfaced by hand during that work:
`os.kill(pid, 0)` counting zombies as alive, and the VNC port drifting upward
on every restart because SIGTERM is asynchronous. Neither would have been
caught by review, and until now nothing stopped either returning.

These run against real processes rather than fixture text. `_alive` reads
`/proc/<pid>/stat`, and a `true` that nobody reaped is a zombie in about
200ms -- so the thing under test is the actual read and the actual parse,
not a seam holding a string somebody typed. `true` and `sleep` are not
cage, wayvnc and Chrome: nothing here starts the real stack.

State is redirected in conftest.py, which is load-bearing -- see the note
there about what `teardown()` would otherwise do to a live session.
"""
import os
import signal
import socket
import subprocess
import sys
import time
import uuid

import pytest

from ab import session
from ab.config import settings


def _state(pid: int) -> str:
    """The process state letter, read without disturbing it."""
    return open(f"/proc/{pid}/stat").read().rpartition(")")[2].split()[0]


def _announcing(source: str, *args: str) -> subprocess.Popen:
    """A python child that prints `ready` once it is, returned once it has.

    Every child here has to reach some state before the assertion means
    anything -- its argv has to be its own, its socket has to be bound -- and
    the tests used to wait for that by polling for the effect, 200 times at
    10ms. Two seconds is a guess at a fork, an exec and an interpreter start:
    it held on this machine and lost in the nix sandbox, where `nix flake
    check` went red on a test that nothing in the commit reached and green on
    an immediate re-run. A gate that is re-run until it passes is not one.

    A child that says when it is ready removes the guess instead of enlarging
    it. The line cannot be printed before the state exists, because the child
    prints it afterwards, so there is no window left to size. If the child
    dies first the pipe closes and the read returns empty, so a broken child
    fails the test rather than hanging it.
    """
    child = subprocess.Popen([sys.executable, "-c", source, *args],
                             stdout=subprocess.PIPE)
    assert child.stdout is not None
    line = child.stdout.readline()
    if line != b"ready\n":
        child.kill()
        child.wait()
        pytest.fail(f"child never announced itself: {line!r}")
    return child


@pytest.fixture
def zombie():
    """A pid that is exited-but-unreaped, which is what Chrome leaves in cage.

    Deliberately never polled: `Popen.poll` waits on the child, and a reaped
    child is not a zombie -- so polling for readiness would quietly destroy
    the thing under test. The state letter is read straight out of /proc
    instead.
    """
    child = subprocess.Popen(["true"], stdout=subprocess.PIPE)
    assert child.stdout is not None
    # A child cannot announce the state this fixture wants -- being dead is
    # not something it can say -- but the empty read is the next best thing:
    # the pipe reaches EOF when the kernel closes the child's descriptors,
    # which is inside the same exit that makes it a zombie. So what the poll
    # below still waits for is the tail of one kernel call, not a fork, an
    # exec and a scheduler under load; two seconds bounds it comfortably
    # where, waiting on the whole exit, it did not. See `_announcing`.
    assert child.stdout.read() == b""
    for _ in range(200):
        if _state(child.pid) == "Z":
            break
        time.sleep(0.01)
    else:
        child.kill(); child.wait(); pytest.fail("no zombie to test with")
    yield child.pid
    child.wait()


@pytest.fixture
def running():
    child = subprocess.Popen(["sleep", "30"])
    yield child.pid
    child.kill()
    child.wait()


def _record(**overrides) -> session.NestedSession:
    fields = dict(cage_pid=os.getpid(), chrome_pid=os.getpid(),
                  vnc_pid=os.getpid(), vnc_host=settings.vnc_host,
                  vnc_port=settings.vnc_port,
                  ctl_socket=session.ctl_socket(settings.vnc_port),
                  wayland_display="wayland-test")
    return session.NestedSession(**{**fields, **overrides})


def _write(record: session.NestedSession) -> None:
    session.SESSION_FILE.parent.mkdir(parents=True, exist_ok=True)
    session.SESSION_FILE.write_text("\n".join(
        f"{key}={value}" for key, value in record.model_dump(mode="json").items()))


# --- _alive ------------------------------------------------------------

def test_a_zombie_does_not_count_as_alive(zombie):
    """The bug: os.kill(pid, 0) succeeds on an unreaped child, so a session
    whose Chrome had died inside cage reported itself live, and the viewer
    showed a black screen with every status agreeing it was fine.
    """
    os.kill(zombie, 0)  # the old check -- still passes, which is the point
    assert session._alive(zombie) is False


def test_a_running_process_is_alive(running):
    assert session._alive(running) is True


def test_a_pid_that_is_not_there_is_not_alive():
    assert session._alive(2**22) is False


# --- the port ----------------------------------------------------------

def test_free_port_takes_the_configured_port_when_nothing_holds_it():
    assert session.free_port() == settings.vnc_port


def test_free_port_steps_over_a_port_someone_else_holds():
    """Scanned rather than fixed so a second session -- or anyone else's
    wayvnc -- cannot silently take the port this one is about to advertise.
    """
    with socket.socket() as held:
        held.bind((settings.vnc_host, settings.vnc_port))
        held.listen()
        assert session.free_port() == settings.vnc_port + 1


def test_teardown_gives_the_port_back_before_it_returns():
    """The port-drift regression, asserted on the port rather than on the pids.

    SIGTERM is asynchronous. A teardown that fired and forgot left the old
    listener holding the port, so the session started immediately afterwards
    quietly claimed a different one and the port climbed on every restart.

    The child dies *slowly* on purpose: against one that exits instantly this
    test would pass even if `_stop_all` never waited at all, and would be
    green for the wrong reason.
    """
    slow = _announcing(
        "import socket, signal, sys, time\n"
        "s = socket.socket(); s.bind((sys.argv[1], int(sys.argv[2]))); s.listen()\n"
        "signal.signal(signal.SIGTERM, lambda *_: (time.sleep(0.5), sys.exit(0)))\n"
        "print('ready', flush=True)\n"
        "time.sleep(30)\n",
        settings.vnc_host, str(settings.vnc_port))
    assert session.free_port() != settings.vnc_port  # it really holds it

    try:
        session._stop_all(_record(vnc_pid=slow.pid, cage_pid=slow.pid))
        assert session.free_port() == settings.vnc_port
    finally:
        if slow.poll() is None:
            slow.kill()
        slow.wait()


# --- the record --------------------------------------------------------

def test_a_malformed_record_reads_as_absent():
    """The caller's next move is to start a fresh session either way, so a
    half-written record must not raise on the way past.
    """
    session.SESSION_FILE.parent.mkdir(parents=True, exist_ok=True)
    session.SESSION_FILE.write_text("cage_pid=1\nnot a pair\nvnc_port=")
    try:
        assert session.current() is None
    finally:
        session.SESSION_FILE.unlink(missing_ok=True)


def test_a_session_whose_chrome_is_gone_is_not_live(zombie, running):
    """The black screen, exactly: cage and wayvnc still up, Chrome dead.

    `alive` is keyed on Chrome because cage outliving it is the stale state
    the record exists to detect.
    """
    _write(_record(chrome_pid=zombie, cage_pid=running, vnc_pid=running))
    try:
        assert session.current() is not None
        assert session.live() is None
    finally:
        session.SESSION_FILE.unlink(missing_ok=True)


# --- the viewer --------------------------------------------------------

def test_viewer_pid_is_keyed_on_the_pid_not_the_name(running):
    """So a VNC client the user opened for something else is never mistaken
    for ours, in either direction.
    """
    session.record_viewer(running)
    assert session.viewer_pid() == running
    session.clear_viewer()
    assert session.viewer_pid() is None


def test_a_viewer_that_died_is_not_reported(zombie):
    session.record_viewer(zombie)
    try:
        assert session.viewer_pid() is None
    finally:
        session.clear_viewer()


def test_pids_running_matches_on_the_command_line():
    """Matched on argv, so the fragment has to be unique to this run.

    A literal like "nothing-runs-with-this" is not: it appears in this file,
    and therefore in the argv of any shell that was handed this file's text --
    which is how the first draft of this test failed against the process that
    wrote it.
    """
    tag = f"agent-browser-test-{uuid.uuid4().hex}"
    # Announced rather than polled for: between fork and exec the child's
    # cmdline is not yet its own, so reading /proc straight away is a race.
    # The announcement closes it, because the kernel sets the cmdline at exec
    # and the child prints only after -- and it closes it exactly, where the
    # poll it replaces only outran it. Walking all of /proc is also the
    # slowest possible way to ask, so that poll got slower under precisely
    # the load that made it necessary.
    child = _announcing(
        f"import time; print('ready', flush=True); time.sleep(30)  # {tag}")
    try:
        assert child.pid in session.pids_running(tag)
        assert session.pids_running(f"absent-{uuid.uuid4().hex}") == []
    finally:
        child.kill()
        child.wait()


def _stubborn(port: int) -> subprocess.Popen:
    """A child that holds the VNC port and ignores SIGTERM outright.

    The slow child above dies in 0.5s, comfortably inside the two-second
    budget, so it cannot reach the case where the budget runs out. This one
    never leaves on its own.
    """
    child = _announcing(
        "import socket, signal, sys, time\n"
        "s = socket.socket(); s.bind((sys.argv[1], int(sys.argv[2]))); s.listen()\n"
        "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        "print('ready', flush=True)\n"
        "time.sleep(60)\n",
        settings.vnc_host, str(port))
    assert session.free_port() != port
    return child


def test_teardown_kills_what_will_not_terminate():
    """The bug: the SIGTERM budget ran out and the record was unlinked anyway.

    That is the port drift of `test_teardown_gives_the_port_back_before_it_
    returns` all over again, and worse -- with the record gone the surviving
    pid is unowned, so `reap_stale` cannot clean up after it either. It needs
    only a wayvnc that takes longer than two seconds to die.
    """
    child = _stubborn(settings.vnc_port)
    _write(_record(vnc_pid=child.pid, cage_pid=child.pid))
    try:
        assert session._stop_all(_record(vnc_pid=child.pid, cage_pid=child.pid)) is None
        assert session.free_port() == settings.vnc_port
        assert session.current() is None
    finally:
        if child.poll() is None:
            child.kill()
        child.wait()
        session.SESSION_FILE.unlink(missing_ok=True)


def test_a_pid_that_survives_even_sigkill_keeps_its_record(running, monkeypatch):
    """Nothing in userspace survives SIGKILL, so `_alive` is stubbed here --
    the state is real (a pid in uninterruptible sleep, or one that is not
    ours) but it cannot be produced honestly from a test.

    What matters is that the record stays: unlinking it is what makes the pid
    unowned, and a record `reap_stale` can still read is the only thing that
    keeps the port attributable to a session someone can name.
    """
    monkeypatch.setattr(session, "_alive", lambda pid: True)
    _write(_record(vnc_pid=running, cage_pid=running))
    try:
        note = session._stop_all(_record(vnc_pid=running, cage_pid=running))
        assert note is not None and str(running) in note
        assert session.current() is not None
    finally:
        session.SESSION_FILE.unlink(missing_ok=True)
