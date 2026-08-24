---
id: 049
title: The skill teaches a door that no longer exists
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

`skills/using-passenger/SKILL.md` is the operating knowledge for this tool, and
every line of code in it is Python against a synchronous Playwright:

    script(lane, source="page.goto('https://example.com')\n"
                        "return page.inner_text('body')")
    return page.locator('#results').inner_text()
    return page.eval_on_selector_all('a[href]', "els => ...")
    walker = <contents of walker.js>
    return page.evaluate(walker)

The C# port's door takes C# on Roslyn against an async Playwright, so every one
of those is wrong at that door -- and the skill is the one thing an agent is
told to read before its first call. The verbs moved too: `open_lane` is
`openLane`, `wait_seconds` is `waitSeconds`, `char_count` is `charCount`.

**Why this is not just a find-and-replace.** Two of the skill's sections are
about *reading* rather than about syntax, and they change more than their code
samples:

- **"Reading a page"** recommends the cheapest thing that answers the question,
  and its escape hatch is that `inner_text` is the only thing that sees
  12306's ticket results. That claim is about the browser, not the binding, so
  it survives -- but the recipe under it becomes `await
  page.InnerTextAsync("body")`, and the `eval_on_selector_all` recipe becomes
  `await page.EvalOnSelectorAllAsync<string[]>(...)`, which needs an explicit
  type argument that the Python has no equivalent of. Ticket 023's measurement
  3 found that type argument to be one of exactly two mechanical differences
  that trip a first try.
- **`walker.js` is unchanged and must stay unchanged.** It runs in the page, so
  the port does not touch it -- but the line that loads it does, and the skill
  is where that line lives.

To decide:

1. **One skill or two.** The Python and C# servers both exist during the
   overlap ([023](023-rewriting-into-csharp.md): it lands alongside, not
   big-bang), so for a while two doors take two languages. One skill with both
   spellings doubles every recipe and is the drift
   [026](026-one-description-two-doors.md) is about; two skills means a caller
   can load the wrong one, and nothing in an MCP handshake says which server it
   is talking to. A third option is that the skill is switched at the moment the
   Python one is deleted, and the overlap is simply lived with.

2. **Whether the C# recipes are actually as cheap.** The skill's advice is
   ordered by cost -- text first, a selector second, the walker last. If a
   Roslyn compile per call changes that ordering, the advice changes, not just
   its examples. Worth measuring rather than assuming: the compile is once per
   distinct source, and this project's callers mostly send a new source each
   time.

3. **What replaces "This server does not interpret pages".** That paragraph is
   the load-bearing one and it is language-independent, so probably nothing.
   Worth confirming rather than assuming, since it is the section that has
   survived six deletions.

4. **Whether the skill should carry the walker at all now.** Raised by
   [048](048-pictures-on-demand.md) from the other direction: if `pictures.js`
   moves *into* the skill, the skill becomes the home of two recipes, and the
   question of how a recipe is versioned against the tool it runs through stops
   being hypothetical.

## Answer

**Two skills, and the tool list is the discriminator.**
`skills/using-passenger-csharp/` is the C# door's operating knowledge;
`skills/using-passenger/` keeps the Python door's, unchanged apart from one
added section.

### Decision 1: one skill or two

Two, and the overlap problem this ticket worried about turned out to be already
solved by the port. It said "nothing in an MCP handshake says which server it is
talking to" -- but the C# door's verbs are camelCase and the Python door's are
snake_case, so the tool list an agent already holds names the door with no round
trip. Both skills now open with a **Which door you are at** section pointing at
the other, and both descriptions carry the same line, so the mistake is
catchable from either side before the first call.

One skill carrying both spellings was rejected: it doubles every recipe, which
is the drift [026](026-one-description-two-doors.md) is about. But the honest
cost of *two* is the mirror of that -- every non-code paragraph is true of both
doors and now exists twice, which is the same drift moved rather than removed.
It is bounded by the overlap: when the Python side is deleted, one of these goes
with it.

### Decision 2: are the C# recipes as cheap? Measured, and yes

The skill's advice is ordered by cost -- text first, a selector second, the
walker last -- so a per-call Roslyn compile could have reordered it. It does not.

| what | compile |
|---|---|
| first compile in a process | 684 ms |
| distinct sources after that | median 37 ms (min 22, max 55) |
| `InnerTextAsync` recipe, 41 chars | 40 ms |
| `Locator` recipe, 55 chars | 34 ms |
| walker recipe, **11,268 chars** | 38 ms |

Flat. An 11 KB source carrying the whole walker compiles in the same time as a
one-liner, so the compile is a constant that cancels out of every comparison the
ordering makes. That ordering was always about how much content comes back and
how many round trips it takes, and that is unchanged.

The 684 ms first compile is why `Script.Warm()` runs at MCP start-up: it moves
that cost off the caller's first call. The skill says not to restructure scripts
to amortise the rest, because batching unrelated work into one script buys ~40 ms
and costs the ability to continue from where a failure left off.

### Decision 3: "This server does not interpret pages"

Unchanged, as suspected. It is language-independent and survived the port along
with the rest of its section. Confirmed rather than assumed.

### Decision 4: the walker

`walker.js` is copied into the new skill directory, byte-identical, and both
copies say they must stay that way. It runs *in the page*, so the port did not
touch it and neither language has a claim on it -- the property
[030](030-the-walker-reads-a-snapshot.md) closed on, holding exactly as
predicted. A skill directory has to be self-contained, so a cross-reference to
the other skill's copy was rejected: it breaks when the Python side is deleted.

### What writing it found

Three things, none of which review would have caught, because each needed the
recipe to be *run*:

1. **`Page`, not `page`** -- fixed just before this ticket, and found the same
   way: the documented snippet did not compile.
2. **A raw string literal is the only sane way to paste the walker.** A verbatim
   `@"..."` needs every quote in 11 KB of JavaScript doubled. A `"""` literal
   needs no escaping, and the walker contains no `"""` to collide with. Both
   were run; the skill documents the second and says why.
3. **A live bug: `IAPIResponse` crossed the tool boundary.** `Crossable` named
   eight handle types by hand and that was not among them, so `return await
   Page.APIRequest.GetAsync(url)` serialised the driver's headers and timings
   and handed them back looking like an answer -- no error, and not the body
   asked for. Fixed by replacing the list with a rule: a handle is anything
   implementing an interface in the `Microsoft.Playwright` namespace, since
   everything there that is *data* is a class or a struct. Two tests, and the
   skill's picture recipe now takes `BodyAsync()`.

That third one is the argument for porting a skill by *executing* every recipe
rather than translating it. The bug had been in the port since the script door
was written, and the suite was green over it.

### Owed

`walker.js` now exists twice and must stay byte-identical, with nothing but a
comment in each enforcing it. If the overlap lasts, that is worth a check.
