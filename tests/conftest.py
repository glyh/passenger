"""Point every state path at a temp directory, before `ab` is imported.

This is a safety mechanism, not a convenience. `ab.config` reads the
environment exactly once, at import, into module-level constants -- so
`session.SESSION_FILE` and `launch.SESSION_SH` are both fixed by the time any
test runs. Without this, a test that called `teardown()`
would SIGTERM the pids in the *developer's real* session record and unlink it,
killing a live browser to run a unit test. The failure mode is destructive
rather than red, which is why it is done here and once, rather than
monkeypatched per test and forgotten in the one that matters.

The VNC port is pinned for a subtler reason. `free_port` scans upward from
`settings.vnc_port`, so a test asserting it returns that port would pass in a
sandbox (private network namespace, 5900 free) and fail on the machine of
anyone with a live session holding 5900 -- green where nobody looks and red
where they do.
"""
import os
import socket
import tempfile

_STATE = tempfile.mkdtemp(prefix="passenger-tests-")


def _unused_port() -> int:
    """A port nothing holds right now, as a base for the scan tests."""
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


os.environ["PASSENGER_STATE"] = _STATE
os.environ["PASSENGER_VNC_PORT"] = str(_unused_port())
