---
id: 074
title: The script door runs on your machine, so stop sandboxing it
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

The owner, asked what `script` restricts today and given the four-item answer:
*"We keep — whatever you return has to be JSON; you have to say which lane
you're in. And remove the other 2. The reason is this tool is supposed to be
running on a local machine."*

The four were:

1. **A short list of names in scope.** `Script.globals` binds `Page`,
   `console`, `fs`, `path`, `setTimeout`, `clearTimeout` into a `node:vm`
   context, and nothing else — a vm context starts with V8's intrinsics and
   none of Node's host objects. `fetch` is absent by name, from [046](046-retire-fetch.md).
2. **What crosses back must be JSON.** *Kept.*
3. **A per-operation timeout, clamped 1–600, defaulting to 60.**
4. **A lane is required, and a tab it does not own is refused.** *Kept.*

(1) and (3) are the ones to go, and the reason given is the whole argument:
this server runs on the machine of the person who registered it, launched by
their own agent, driving their own logged-in Chrome. `Script.res` already said
the quiet part — *"deliberately not a sandbox, and not pretending to be one: a
caller-supplied script runs in this process either way, and what is missing
here is still reachable by other means."* A list that stops an accident but
not an intent, on a process that already has the user's cookies, is paying a
real cost for nothing.

Two things inside (1) and (3) are *not* sandbox restrictions wearing that
name, and both survive:

- **`console` goes to stderr.** stdout is the JSON-RPC transport. Handing over
  the real `console` means one `console.log` in a caller's script corrupts the
  stream it is travelling on. That is protocol correctness, not confinement.
- **`timeoutSeconds` itself.** It never bounded a script — it is Playwright's
  `setDefaultTimeout`, a budget for each *single* browser operation, so ten
  clicks at 60 is ten minutes and a `while(true)` is forever. The clamp and the
  forced default go; the knob stays, optional, and gets a name that says what
  it is.

And this needs saying somewhere a reader hits early, since it is now the
premise the design rests on rather than a deployment detail: **passenger runs
on your machine.**

## Answer

**Both removed.** A script's scope is this process's scope, and the timeout is
optional.

`Node.runInThisContext` replaces `runInContext`, and `Node.wrap` builds an
async *function expression* over the names in `Script.bound` rather than an
IIFE over nothing. So `fetch`, `URL`, `TextEncoder`, `Buffer`, `process`,
`structuredClone`, `AbortController` and the timers are simply there, because
they are there for the file that runs them. Measured over the live door:

    return [typeof fetch, typeof process, require('node:os').platform()].join();
    -> "function,object,linux"

Five names are still handed in, as arguments:

    Page      the door itself
    console   rebuilt onto stderr, and passed as an argument so that it
              *shadows* the real global rather than relying on the caller
    fs/path   every recipe in the skill uses them; `require` reaches the same
              modules, these save the ceremony
    require   `createRequire`, because ES module scope has no `require` to
              inherit

The wrapper still adds exactly one line and no newline before the body, which
is what `where` and the syntax-error path depend on. Both verified: a throw on
line 3 still reports `line 3: throw new Error("boom")`, and `var y = (;` on
line 2 still reports line 2.

`timeoutSeconds` is `operationTimeoutSeconds`, optional, `minimum: 0`, no
maximum. Absent leaves Playwright's own 30s alone -- `Service.run` does not
call `setDefaultTimeout` at all -- and 0 is Playwright's spelling of no limit.
The rename is the substantive half: the old name read as a budget for the
script, and the docs had to keep correcting it. It is a budget for one
*operation*, and nothing bounds a script that never calls Playwright.

**What did not change, and why it looked like it should have.**

`console` to stderr stays, at any level of trust: stdout is the JSON-RPC
transport, so a caller's `console.log` reaching the real one corrupts the
stream it is travelling on. That is protocol correctness, not confinement.

Ticket [046](046-retire-fetch.md) is not reversed. It deleted the `fetch`
*tool* and the extraction modes on it, and that stands. What it also did --
leave the *function* out of `Script.globals` -- was making a design point by
withholding a name, and the point survives without the withholding:
`Page.request` goes through the browser's context and `fetch` does not, so a
recipe reaching for `fetch` has misunderstood the tool. The skill says so now
instead.

The test that asserted the wall is gone, replaced by three that assert what is
true: node's globals are in scope, a name nobody bound is still a
`ReferenceError` at the caller's own line, and `console` is not the global one.
It also stopped reaching example.com to prove a negative -- 258ms of network in
a unit suite.

**Written down where a reader hits it.** The premise was implicit and is now
the README's second paragraph, a load-bearing rule in `CLAUDE.md`, and the
opening of `references/writing-scripts.md`. The rule carries the sentence the
next session needs: do not re-add a wall here without a ticket that first says
who is on the other side of it.
