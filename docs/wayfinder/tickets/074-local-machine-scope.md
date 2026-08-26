---
id: 074
title: The script door runs on your machine, so stop sandboxing it
labels: [wayfinder:task]
status: open
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
   none of Node's host objects. `fetch` is absent by name, from [046](046-delete-fetch.md).
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
