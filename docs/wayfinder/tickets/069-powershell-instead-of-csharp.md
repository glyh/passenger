---
id: 069
title: Would PowerShell be a better script language than C# for this door?
labels: [wayfinder:research]
status: open
assignee:
blocked_by: []
---

## Question

`script` takes C# and compiles it with Roslyn (`src/Passenger/Script.cs`).
That was inherited rather than chosen: the Python door took Python because the
server was Python, and when [053](053-delete-the-python-door.md) deleted it the
surviving door took C# because the server is C#. Nobody has asked whether the
language a caller writes should follow the language the server is written in.

The evidence that it might not is
`skills/using-passenger/references/writing-scripts.md`, which exists entirely
because C# bites. Splitting its entries by whose fault they are:

**The language's, and PowerShell would or might fix them**

- Verbatim strings. A JS snippet carrying `.split('\n')` breaks in an ordinary
  C# string and needs `@"..."` with doubled quotes. PowerShell's single-quoted
  here-string (`@'...'@`) is literal with no doubling at all, which is a
  strictly better shape for the thing every script does most.
- The nested `await` that will not compile at the top level.
- `JsonSerializer`'s ASCII-escaping default, per [068](068-json-encoder-in-scope.md).
  `ConvertTo-Json` on PowerShell 7 is believed not to ASCII-escape -- verify,
  do not assume.
- Local functions having to precede the `return`.

**Not the language's, and no door change touches them**

- Guarding `.innerText` on the JS side.
- Navigation destroying the execution context mid-script.
- `timeoutSeconds` being per-operation.
- A missing `tab` answering about `about:blank` instead of failing.
- Live Playwright handles not being able to cross back.

So roughly four of nine, and the four are the smaller ones.

**What PowerShell would cost, and this is the half to measure first**

- **Async.** Playwright .NET is async-only and PowerShell has no `await`.
  Every call becomes `.GetAwaiter().GetResult()` or `$t.Result` -- noisier than
  `await` on the exact call a script makes most, and with its own deadlock
  hazards depending on the synchronisation context the runspace runs under.
  This alone could sink it; establish it before anything else.
- **Generics.** `EvalOnSelectorAllAsync<string[]>` is already the most-missed
  detail in the C# door. PowerShell 7.3 added a generic-method invocation
  syntax; whether it reaches this call cleanly is unverified.
- **Return semantics.** PowerShell has no single return value -- it emits a
  pipeline, and anything not captured joins the success stream. A script whose
  stray expression silently becomes part of `returned` is the same class of
  hazard as a stray `Console.WriteLine` on stdout, and `Script.Crossable`
  (`src/Passenger/Script.cs:183`) would be handed `PSObject` wrappers to unwrap
  before any of its checks mean what they say.
- **Weight.** Roslyn scripting is already in the closure. Hosting PowerShell
  means `Microsoft.PowerShell.SDK`, and [060](060-trim-the-closure.md) spent a
  whole ticket removing 135 MiB of interpreter that nothing ran.
- **Line numbers.** Ticket 023 bought a runtime line number for C# with a file
  path and debug information. Whatever PowerShell gives has to be at least
  that, or every failure gets worse to fix.

**The question underneath all of it** is not which language is nicer but which
one a model writes correctly on the first try against Playwright .NET, which is
a measurement, not an opinion. `docs/wayfinder/assets/044-acceptance-set.md`
already exists for exactly this kind of comparison: run the same set through a
PowerShell door and count first-try successes against the C# baseline. Anything
short of that is preference.

Note also that this need not be exclusive. Nothing about `script` forbids a
`language` parameter -- but ticket 004's "one door onto a page" is about not
multiplying ways to do the same thing, and two languages is two doors wearing
one name. If PowerShell wins, it should replace C#, not join it.
