---
id: 024
title: Teardown gives up quietly
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
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

## Answer

**SIGTERM is escalated, and the record is kept in the one case where even
that fails.** The shrug is gone: `_stop_all` now sends SIGTERM, waits the
same two seconds, SIGKILLs whatever is left, waits two more, and only then
unlinks the control socket and the session record. A note comes back
naming any pid that survived both.

1. **What teardown does when something will not die.** It kills it. The
   escalation was the obvious answer and the objection to it -- wayvnc
   leaving its control socket behind when it does not exit cleanly -- turned
   out to be already paid for: `_stop_all` unlinks `session.ctl_socket`
   itself, and has since the socket became per-port. There was no new cost
   to weigh.

2. **Not "leave the record for `reap_stale`" on its own**, because that
   does not converge. `reap_stale` calls `_stop_all`, so a record left
   behind for it buys another SIGTERM against a process that already
   ignored one. Attribution without escalation just defers the same shrug
   to the next run. The two halves are only useful together, and they are
   now split by outcome: SIGKILL settles it, or the record stays.

   It stays in the residual case for the reason the ticket gives -- an
   unowned listener is the worse half of the bug. The control socket stays
   with it, since a surviving wayvnc may still be serving it.

3. **The caller is told.** `_stop_all` returns `str | None`; `teardown`
   and `browser.stop` pass it up, and `agent-browser stop` prints it in
   place of "stopped". `reap_stale` already had a channel and now writes
   the survivor onto the end of it, which `browser.start` appends to the
   line it returns -- a reap that could not finish is exactly the moment
   the new session is about to advertise a port one higher than the last.

4. **Two seconds was the right budget, for what it was for.** It covers
   SIGTERM being asynchronous, which is a fast thing; it was never a budget
   for a wedged process, and the fix is not to make it longer. The SIGKILL
   wait is the same two seconds and is nearly always unused -- nothing in
   userspace survives it. What can is a pid in uninterruptible sleep, or
   one that is not ours after pid reuse, which is the map's pid-reuse fog
   seen from the other side.

### Tested

Two tests in `tests/test_session.py`, alongside the port-drift one they
extend:

- `test_teardown_kills_what_will_not_terminate` -- a real child that binds
  the VNC port and sets `SIGTERM` to `SIG_IGN`. Against the old code the
  port is still held when `_stop_all` returns, which is the failure the
  ticket describes, on the port rather than on the pid.
- `test_a_pid_that_survives_even_sigkill_keeps_its_record` -- `_alive` is
  stubbed, and the docstring says why: the state is real but cannot be
  produced honestly from a test. The assertion is that the record is still
  readable and the note names the pid.
