---
id: 069
title: Would PowerShell be a better script language than C# for this door?
labels: [wayfinder:research]
status: closed
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
- `JsonSerializer`'s ASCII-escaping default, per
  [068](068-json-encoder-in-scope.md). **Measured, 7.6.5:** `ConvertTo-Json`
  escapes nothing -- `@{t="腾冲"; e="😀"}` comes out as
  `{"e":"😀","t":"腾冲"}`, emoji included, which is more than the C# side
  manages ([070](070-astral-still-escapes.md)).
- Local functions having to precede the `return`.

**Not the language's, and no door change touches them**

- Guarding `.innerText` on the JS side.
- Navigation destroying the execution context mid-script.
- `timeoutSeconds` being per-operation.
- A missing `tab` answering about `about:blank` instead of failing.
- Live Playwright handles not being able to cross back.

So roughly four of nine, and the four are the smaller ones.

**What PowerShell would cost.** Three of these were guesses when this ticket
was opened; they have since been run against PowerShell 7.6.5, and two of the
three did not survive.

- **Async.** Playwright .NET is async-only, and **measured on 7.6.5, there is
  no `await`**: `await <expr>` raises `CommandNotFoundException`, no
  `Wait-Task`/`Receive-Task` exists, and a returned `Task` does not unwrap
  itself (it comes back as `AsyncStateMachineBox\`1`). The shape is
  `.GetAwaiter().GetResult()` on every Playwright call, which is 26 characters
  of ceremony on the operation a script performs most. The deadlock worry is
  *not* confirmed: a bare runspace reports no `SynchronizationContext`, so
  blocking there is safe. Whether that holds for a runspace hosted inside
  `Passenger.Mcp` is the part still to establish, and it is the one that could
  sink this.
- ~~**Generics.**~~ **Settled, and not a cost.** `Method[Type](args)` works:
  `[System.Text.Json.JsonSerializer]::Deserialize[string[]]('["a","b"]')`
  returns the array, and `[Enumerable]::Empty[string]()` types correctly. So
  `EvalOnSelectorAllAsync<string[]>` translates, and PowerShell's syntax makes
  the type argument no easier to forget than C#'s does.
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
a measurement, not an opinion. **There is nothing in this repo to measure it
with, and that is this ticket's first job.** An earlier draft of these lines
pointed at `docs/wayfinder/assets/044-acceptance-set.md`; that is five web
pages with extraction diagnostics, and it tests whether a reading recipe
survives a comments rail -- not whether a script compiles and runs first try.
What is needed instead is a set of *scripting tasks* with known-good answers
(fetch a JSON endpoint and pull three fields, scroll a feed to a count, click
through to a detail page, screenshot a region), run through both doors and
scored on first-try success. Building that set is most of the work here, and
it is worth having whatever the answer turns out to be: `writing-scripts.md`
grew from nine bites to eleven while this ticket was being written, entirely
from failures caught by hand.

Note also that this need not be exclusive. Nothing about `script` forbids a
`language` parameter -- but ticket 004's "one door onto a page" is about not
multiplying ways to do the same thing, and two languages is two doors wearing
one name. If PowerShell wins, it should replace C#, not join it.

## Answer

**Moot, as this ticket said it would be.** [071](071-port-to-node.md) is closed:
the server is ReScript on node and the caller's script is JavaScript, so there
is no C# left for PowerShell to be better than.

What survives is the question underneath, and 071 inherits it rather than
answering it: **there is still no scripting-task acceptance set in this repo.**
This ticket wanted one to compare two languages; 071 wanted one to prove
patchright behaves the same driven directly as through the .NET binding. The
same missing artefact blocked both, and the port went ahead on a narrower
measurement -- one real round of a site skill -- rather than on it. Whoever
builds that set should read this ticket's notes on what a fair one looks like.
