---
id: 001
title: What the test suite covers, and how the shells get tested
labels: [wayfinder:grilling]
status: open
assignee:
blocked_by: []
---

## Question

The project has no tests at all -- only strict mypy. The session
correlation logic committed in 5275197 was verified by hand, against live
cage/wayvnc/Chrome processes, and two real bugs surfaced only during that
manual pass: `os.kill(pid, 0)` counting zombies as alive, and ports
drifting upward because SIGTERM is asynchronous. Neither would have been
caught by review, and nothing stops either from regressing.

What should the test suite cover, and where are the seams?

The codebase is deliberately split functional-core / imperative-shell, so
the answer differs sharply by module:

- **Already pure and cheaply testable**: `detect.classify`, the models'
  validators, `extract`. These need only a decision to start.
- **Shells with a pure kernel worth extracting**: `session.py` mixes
  parsing (`_parse`, `NestedSession` validation), process predicates
  (`_alive` reading `/proc/<pid>/stat`), and effects (SIGTERM, unlink).
  The zombie bug lived in the predicate -- the part that could be tested
  against fixture text rather than a live process.
- **Genuinely effectful**: `browser.start`, `launch.plan` writing the
  session script, `present.present` spawning a viewer. Testing these means
  choosing between fakes, a temp-dir + fake-binary harness, or accepting
  they stay manually verified.

Decide, at minimum:

1. Which framework, and whether it lands in `[dependency-groups] dev`
   alongside mypy, plus how it is run inside the nix dev shell.
2. Whether `_alive` and the session-script rendering get pure seams so
   the zombie and port-drift regressions are testable without processes.
3. Whether anything spawns real processes in the suite, or whether that
   tier stays a documented manual checklist.
4. What coverage bar, if any, is worth asserting -- given that the most
   dangerous code here is the least test-friendly.
