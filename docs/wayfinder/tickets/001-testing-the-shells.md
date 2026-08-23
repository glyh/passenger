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

(Premise corrected after this was written: a suite exists now -- 25 tests,
arrived alongside tickets 007, 008, 012 and 013. It covers only the pure
tier, so everything below still stands. See the update at the end.)

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

## Update, three tickets later

The opening premise is stale: a suite exists. It arrived unannounced,
a few tests at a time, alongside the changes that needed them --
[Word counts assume spaces](008-word-counts-assume-spaces.md) brought
`test_text`, [A listing read through dom mode has no link
targets](007-links-lost-in-dom-mode.md) added to it, [One wedged tab
bricks every later call](012-one-wedged-tab-bricks-every-call.md)
brought `test_targets`, and [The passthrough tool that runs a script
against a page](013-the-passthrough-tool.md) brought `test_script`.

    tests/test_text.py       9   count_words, unlinked
    tests/test_extract.py    4   choose
    tests/test_detect.py     3   classify
    tests/test_script.py     6   execute, and its refusals
    tests/test_targets.py    3   Target parsing
                            25   pass in 0.51s

So question 1 has been answered by practice rather than by decision:
pytest, configured in `pyproject.toml` under `[tool.pytest.ini_options]`
with `pythonpath = ["."]` because the dev shell carries the dependencies
and not `ab` itself, and supplied by nix (`flake.nix`, `ps.pytest`)
rather than by a `[dependency-groups] dev`. Worth ratifying or changing
deliberately, but not worth deciding from scratch.

**Questions 2 through 4 are untouched, and they were the point.** Every
test written so far is on the tier the ticket called "already pure and
cheaply testable". Nothing at all covers:

    browser  cli  config  geometry  handoff  launch  mcp_server
    notify  present  probe  service  session  webserve

`session.py` still mixes all three kinds -- `_alive` still reads
`/proc/<pid>/stat` at line 59, with no seam -- so the zombie bug and the
port drift that motivated this ticket remain exactly as untestable as
they were. `geometry.py` is pure arithmetic and untested; so are the
models' validators, which is the other half of the "needs only a
decision to start" list.

What this ticket is now for is therefore narrower and sharper than what
it was written for: not "should there be tests" but "the dangerous half
still has none, and the seams named in 2 have not been cut."
