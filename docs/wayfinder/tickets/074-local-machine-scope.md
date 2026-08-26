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

The scope change is one line: the object handed to `vm.createContext` is
`Object.create(globalThis)` rather than a flat dictionary. A vm context starts
with V8's intrinsics and none of node's globals, which is why the old version
had to name every global a caller might want and why leaving `fetch` off that
list looked like a rule. Giving the context object node's real global as its
**prototype** ends it: a global lookup is an ordinary [[Get]] and walks the
chain. Measured through the live door:

    return [typeof fetch, typeof Buffer, typeof process, typeof structuredClone].join();
    -> "function,function,object,function"

Five names are set as own properties of that object:

    Page      the door itself
    console   rebuilt onto stderr
    fs/path   every recipe in the skill reads a walker off disk and writes back
              the bytes that cannot cross as JSON
    require   `createRequire`, because ES module scope has no `require` to
              inherit -- and it is the *only* module loader here, since a vm
              context has no dynamic-import callback and `import()` throws

Two properties of putting them there rather than around the source:

- **A caller's own `const` shadows them.** Top-level `const` in a vm context
  lands in that context's lexical scope, consulted before the global object, so
  `const path = "/tmp/pep8.md"` -- which the skill's own recipe writes -- names
  the caller's variable. Both meanings work: bare `path` is still the module.
- **They are per call, so nothing races.** Two lanes calling `script` at once
  get a context object each.

`Node.res` is untouched by this ticket. It is byte-identical to its state
before, and `Node.wrap` is the same async IIFE it has always been.

⚠️ **Recorded because it was nearly shipped:** the first implementation opened
the scope by making the wrapper an async *function of the bound names* and
running it with `runInThisContext`. It worked, and it cost two things. The
bound names became parameters, so `const path = "/tmp/x.md"` was a
redeclaration -- `SyntaxError: Identifier 'path' has already been declared`,
before the browser is touched, on a line this repo's own skill tells callers to
write. The fix for *that* was a nested block around the caller's source, and
the fix for the block was unbinding `path` -- each patch covering the last.
The context object does the whole job with none of them. **When a change starts
needing shape imposed on the caller's source, the mechanism is in the wrong
place.**

`timeoutSeconds` is `operationTimeoutSeconds`, optional, `minimum: 0`, no
maximum. Absent leaves Playwright's own 30s alone -- `Service.run` does not call
`setDefaultTimeout` at all -- and 0 is Playwright's spelling of no limit. The
rename is the substantive half: the old name read as a budget for the script,
and the docs had to keep correcting it. It is a budget for one *operation*, and
nothing bounds a script that never calls Playwright.

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

The test that asserted the wall is gone, replaced by five that assert what is
true: node's globals are in scope, a name nobody bound is still a
`ReferenceError` at the caller's own line, `console` is not the global one, a
caller's `const` shadows a bound name, and `require` is the only module loader.
It also stopped reaching example.com to prove a negative -- 258ms of network in
a unit suite.

**Written down where a reader hits it.** The premise was implicit and is now
the README's second paragraph, a load-bearing rule in `CLAUDE.md`, and the
opening of `references/writing-scripts.md`. The rule carries the sentence the
next session needs: do not re-add a wall here without a ticket that first says
who is on the other side of it.
