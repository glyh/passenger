---
id: 001
title: What the test suite covers, and how the shells get tested
labels: [wayfinder:grilling]
status: closed
assignee: lyh (via Claude)
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

## Answer

**The suite is a list of scars.** No coverage bar, and no test written
because a module lacked one -- a test earns its place by naming a failure
that actually happened. That is how the existing 27 arrived anyway, one
ticket at a time; this makes it the rule rather than the accident.

Built in this pass: `tests/conftest.py` and `tests/test_session.py`,
eleven tests, and a `nix flake check`.

### Question 2: no seam. The premise was wrong

The ticket asked whether `_alive` should get a pure seam "so the zombie
regression is testable without processes". It does not need one. A real
zombie is `subprocess.Popen(["true"])` left unreaped, and it is a zombie
in about 200ms -- so the test runs against the actual `/proc` read and the
actual parse, rather than against a fixture string I would have written
myself. A seam here would have tested the half least likely to be wrong.

Real processes, then, but only `true` and `sleep`: **nothing in the suite
starts cage, wayvnc or Chrome.** That answers question 3 -- the
process-spawning tier the ticket worried about turned out to have a cheap
middle that is neither a fake nor the real stack.

### Question 4: no bar, by construction

A percentage would push the suite toward the pure modules, which are the
ones that have never broken. Thirteen modules still have no tests and
that is the correct state for them today.

### Question 1: ratified, plus the half it never asked

pytest, configured in `pyproject.toml`, supplied by nix rather than a
`[dependency-groups] dev`. The unanswered half was *how it is run*, and
the answer is `nix flake check` -- one command from a clean checkout,
against the pinned interpreter, with no CI to maintain for a repo that
has no remote. Deliberately not `packages.default`'s `checkPhase`: these
tests spawn processes and bind a port, and an environment fault should
read as a failing check rather than an unbuildable package.

### What the tests actually assert

The port-drift regression asserts **the port came back**, not that the
pids died. The pid version would stay green through the hole described
below; the port version is the bug as it was experienced. Its child dies
*slowly* on purpose -- against an instantly-exiting child the test passes
even if `_stop_all` never waits, which is green for the wrong reason.

All of it verified by reverting the fixes: restoring `os.kill(pid, 0)`
breaks three tests, and removing the teardown wait breaks the port test.
A regression test that has never failed is a claim, not a check.

### `conftest.py` is a safety mechanism, not a convenience

`ab.config` reads the environment once, at import, into module-level
constants. Without redirection, a test calling `teardown()` would SIGTERM
the pids in the developer's *real* session record and unlink it -- the
failure mode is a killed browser, not a red test. One env var set before
`ab` is imported redirects `SESSION_FILE`, `VIEWER_FILE`,
`launch.SESSION_SH` and the signature registry together.

`AGENT_BROWSER_VNC_PORT` is pinned for a subtler reason: `free_port`
scans upward from it, so a test asserting it returns that port passes in
a sandbox and fails on any machine with a live session holding 5900 --
green where nobody looks, red where they do.

### Two things learned the hard way, kept in comments

- **A flake check only sees git-tracked files.** The first run reported
  "27 passed" against a tree that did not contain the new tests, which is
  a confident green from a suite that was not there.
- **`Popen.poll()` reaps.** The first zombie fixture polled for readiness
  and destroyed the zombie it was creating.

### What this did not cover

`browser.py`'s wedged-tab recovery needs a real Chrome; `present.py`'s
`_prepared` drives CDP and `wlr-randr`. Both have scars and neither is
reachable under the rule above. `present.WebPresenter.available` --
ticket 4b010cc, claiming a noVNC server that is not there -- is testable
with a real socket the same way `free_port` is, and is the obvious next
one if this suite grows.

Surfaced while grilling and split out: [Teardown gives up
quietly](023-teardown-gives-up-quietly.md).
