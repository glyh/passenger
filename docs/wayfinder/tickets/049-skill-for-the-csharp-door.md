---
id: 049
title: The skill teaches a door that no longer exists
labels: [wayfinder:task]
status: open
assignee:
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
