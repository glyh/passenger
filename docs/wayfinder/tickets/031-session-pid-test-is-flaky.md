---
id: 031
title: The pid test loses its race in the nix sandbox
labels: [wayfinder:task]
status: open
assignee:
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
