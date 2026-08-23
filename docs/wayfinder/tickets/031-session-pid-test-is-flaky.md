---
id: 031
title: The pid test loses its race in the nix sandbox
labels: [wayfinder:task]
status: closed
assignee: claude
blocked_by: []
---

## Question

`nix flake check` -- the repo's one gate -- went red on
`test_pids_running_matches_on_the_command_line`, and green on an immediate
re-run of the same derivation with the same inputs. Observed while closing
[The root heuristic picks a decoy](028-the-root-heuristic-picks-a-decoy.md),
which touches nothing that test reaches.

The test spawns a child tagged with a uuid and polls `session.pids_running`
for it. The race is already known -- there is a comment on it, and the poll
exists because of it -- but the bound is 200 iterations of 10ms:

    for _ in range(200):
        if child.pid in session.pids_running(tag):
            break
        time.sleep(0.01)
    assert child.pid in session.pids_running(tag)

Two seconds is a guess, and under load the sandbox exceeds it. `pids_running`
walks all of `/proc` on every iteration, so the poll gets slower exactly when
the machine is busy.

To decide:

1. Whether the bound is simply too low, or whether polling `/proc` in a loop
   is the wrong way to wait for a child to finish exec'ing at all.
2. What a flaky gate costs here. There is no CI and no remote, so a red check
   is read by one person, who will learn to re-run it -- which is how a gate
   stops being one.

## Answer

The bound was not too low; polling was the wrong instrument. Every child
in `test_session.py` now announces itself -- `print('ready', flush=True)`
once it is in the state the assertion needs -- and the test reads that one
line before asserting. Four `range(200)` loops are gone, and with them the
guess: the kernel sets `cmdline` at exec and the child prints after, so the
window the poll was outrunning no longer exists to be sized. A child that
dies before announcing closes the pipe, so the read returns empty and the
test fails with what it got rather than hanging.

The pid test was the worst-placed of the four. `pids_running` walks all of
`/proc` on every iteration, so the poll cost grew with exactly the load that
made it necessary -- under a `nix flake check` sharing the machine with a
build, `/proc` is large and each of the 200 turns pays for it. The two
port-holding children (`test_teardown_gives_the_port_back_before_it_returns`
and `_stubborn`) made the same bet at greater odds, since they waited on a
Python interpreter start, and were rewritten the same way. Their old poll
also asked a weaker question -- `free_port() != port` says *someone* holds
it -- which survives as a one-line assertion after the handshake instead of
as the wait itself.

The `zombie` fixture is the one that cannot be fixed this way: being dead is
not a thing a child can say. It reads its stdout to EOF instead, which the
kernel delivers inside the same `exit` that makes it a zombie, so the poll
that remains waits on the tail of one kernel call rather than on a fork, an
exec and a scheduler.

On the second question: the flaky gate would have cost everything. There is
no CI and no remote, so `nix flake check` is read by one person, and a check
that goes green on a re-run teaches that person to re-run it -- after which
a real failure is indistinguishable from the noise they have learned to
dismiss. That is why the bound was not simply raised: a larger guess is
still a guess, and it fails the same way later, when there is more history
of ignoring it.

Not reproduced locally: at 8x CPU oversubscription the child's cmdline
became visible in a median of 37ms and at worst 101ms, twenty times inside
the old budget, so the fix is argued from the ordering rather than from a
red test made green. `nix flake check` passes.
