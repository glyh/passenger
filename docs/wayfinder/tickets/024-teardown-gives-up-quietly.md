---
id: 024
title: Teardown gives up quietly
labels: [wayfinder:task]
status: open
assignee:
blocked_by: []
---

## Question

Surfaced while grilling [What the test suite covers, and how the shells
get tested](001-testing-the-shells.md).

`_stop_all` SIGTERMs wayvnc and cage, then polls `_alive` twenty times at
0.1s. If they are still up after two seconds it **falls out of the loop
and unlinks the session record anyway**:

    for _ in range(_EXIT_POLLS):
        if not any(_alive(pid) for pid in (session.vnc_pid, session.cage_pid)):
            break
        time.sleep(_POLL_INTERVAL_S)
    session.ctl_socket.unlink(missing_ok=True)
    SESSION_FILE.unlink(missing_ok=True)

So the exact drift that commit 5275197 fixed can still happen -- a
listener holding the port while the record that names it is deleted, and
the next `free_port` climbing past it. It just needs a wayvnc that takes
longer than two seconds to die, and it happens with nothing reported.

Worse than the original in one way: the record is gone, so `reap_stale`
cannot clean up after it either. The pid is now unowned.

The regression test written in 001 does not catch this, and this is
recorded on that ticket: its child dies in 0.5s, comfortably inside the
budget. Catching it needs a child that ignores SIGTERM outright.

To decide:

1. What teardown should do when something will not die. Escalating to
   SIGKILL is the obvious answer and is not free -- wayvnc leaves its
   control socket behind when it does not exit cleanly, and that socket
   is per-port state the next session has to not trip over.
2. Or whether it should refuse to unlink and leave the record, so
   `reap_stale` owns the problem on the next run. That keeps the pid
   attributable, at the cost of a record that describes a session nobody
   can use.
3. Either way, whether the caller is told. Both `teardown` and
   `reap_stale` return before the work is done today, and `reap_stale`
   already returns a string describing what it killed -- so there is a
   channel for "and this one would not go" that nothing writes to.
4. Whether two seconds is even the right budget. It was picked to cover
   SIGTERM being asynchronous, not to cover a process that is wedged.
