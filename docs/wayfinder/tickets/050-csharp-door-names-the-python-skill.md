---
id: 050
title: The C# door sends its caller to the Python skill
labels: [wayfinder:task]
status: closed
assignee:
blocked_by: []
---

## Question

[049](049-skill-for-the-csharp-door.md) decided two skills, discriminated by the
verb casing an agent already holds in its tool list, and both skills open with a
**Which door you are at** section pointing at the other. That half works. The
half it did not check is that the C# server's own instruction text — the
paragraph an agent reads *before* it has any skill at all — names the wrong one:

    dotnet/src/Passenger.Mcp/Program.cs:57   "the `using-passenger` skill. Load it before the first call."
    dotnet/src/Passenger.Mcp/Tools.cs:17,94,107
    dotnet/src/Passenger.Cli/Program.cs:65

So the default path at the C# door is: read the server instructions, load
`using-passenger`, write Python, fail. The **Which door** section is recovery
*after* the wrong file is already in context, and it only fires if the agent
notices the mismatch rather than trusting the pointer it was just handed. 049
called the tool list a discriminator that needs no round trip — true, but only
for an agent that thinks to look at it, and this text tells it not to.

A find-and-replace in four places, except for one question: whether `Tools.cs`
should name a skill at all, or say "the skill for this server's door" and let
the **Which door** sections do the routing. Naming it is what drifted; not
naming it costs the agent the one string it can search for.

### What a skill eval found alongside it

Twelve runs (three tasks × {Python, C#} × {skill, no skill}), logging every
`script` call and its error code. All twelve produced correct output. The
headline is that **the skill never showed lift, and once showed harm**:

| task | py+skill | py base | C#+skill | C# base |
|---|---|---|---|---|
| xkcd image bytes | 2 calls, 0 fail | 2, 0 | 2, 0 | 2, 0 |
| HN front page → JSON | 1, 0 | 1, 0 | 1, 0 | 2, 0 |
| PEP 8 → markdown | 4, 2 rework | 3, 2 | **4, 2 failed + 1 rework** | 4, 2 |

The image outputs were byte-identical across all four conditions. Capable agents
reasoned their way unaided to both of the things the C# skill claims as its own
— ask an `IAPIResponse` for `BodyAsync()` rather than returning it, and get
bytes out by writing from inside the script since they cannot cross — and the C#
baseline reported that the `script` schema's own `source` description already
carries the PascalCase-async convention and the JSON-only return rule that three
of the C# skill's seven extra blocks restate. Only the third task cost anyone a
failed call, and there the *shipped recipe was the cause*: see
[052](052-walker-escapes-do-not-survive-transport.md), where the walker's `\u`
escapes did not survive transcription and the skill's paste-it-in-a-raw-literal
paragraph told the agent in advance that the step it had just done correctly was
the hazard. Neither baseline, writing its own extractor, hit anything like it.

What the runs converged on instead is three things **neither** skill says, each
of which cost every agent a guess or an extra call:

1. **Does a script share the caller's filesystem?** All four eval-0 runs needed
   bytes on disk, none could return them (`json.dumps(bytes)` raises, so
   `SCRIPT_RETURN_NOT_JSON`), and all four independently bet that
   `File.WriteAllBytes` / `open(path,'wb')` from inside the script writes to
   *this* machine. It does. One agent verified it after the fact with `md5sum`
   and said it was "the single fact I'd most want a skill to state outright";
   another said knowing it upfront would have made the task one call instead of
   two. Both skills' picture recipes show returning bytes or screenshotting to a
   `path=` without ever saying where that path lands.

2. **`largest_image` / `largestImageSrc` can name a different asset than the
   `<img src>` the reader sees.** On xkcd 2347 the measurement points at
   `dependency_2x.png` (the retina variant), not `dependency.png`. Both skills
   teach the *number* carefully and say nothing about the `src` beside it.

3. **The recipe's own silent failures.** xkcd's `src` is protocol-relative
   (`//imgs.xkcd.com/...`) and needs a scheme before `page.request.get`; the
   hover text is the `title` attribute, not `alt`, and taking `alt` yields a
   plausible wrong string with no error. Both are exactly the shape these skills
   otherwise document well — a read that succeeds and is wrong — and both are in
   the one recipe the skills ship.

### The asymmetry between the two files

`using-passenger-csharp` is a strict superset: same twelve sections in the same
order, `walker.js` byte-identical (verified), plus seven blocks. Four are
honestly C#-only — `Page` capitalised, everything awaited, the
`EvalOnSelectorAllAsync<T>` type argument, the raw-string literal for the walker,
the flat ~40 ms compile. Three are not:

- **`SCRIPT_RETURN_NOT_JSON` has no section in the Python skill.** `script.py:57`
  `crossable()` refuses the same values for the same reason, and returning a
  `Locator` is as easy a mistake against the sync API as the async one. The C#
  file gets a whole *What cannot cross back* section; the Python file gets
  nothing.
- **The Python picture recipe is a dead end as written.** It shows
  `page.request.get(src)` with no continuation. The response cannot cross, and
  neither can `.body()` — `bytes` is not JSON. The C# side spells out
  `BodyAsync()` *and* warns against returning the response. (Both eval agents
  worked around it unaided, so this is a documentation defect, not a blocker.)
- **The "Nothing else distinguishes them" sentence** exists only in the C# file,
  and it is the sentence that actually stops the wrong-door mistake — in the file
  *less* likely to be opened by accident.

The last one is this ticket's own bug seen from the other side: the routing text
is asymmetric in exactly the direction that hurts.

### To decide

1. Whether fixing the four server strings is enough, or whether the server
   should stop naming a skill and describe the door instead.
2. Whether the three convergent findings above go in both skills, or in the tool
   schemas — (1) is a fact about the *tool*, not about either language, and
   `CLAUDE.md`'s rule is that tool facts live with the tool and are cited by
   name, never copied into six skills.
3. Whether the Python skill gets *What cannot cross back* and a working picture
   recipe, or whether — given the overlap ends when the Python door is deleted —
   it is left to die as it is. The eval says the gap costs a capable agent
   nothing measurable.

## Answer

*Closed 2026-08-24, by construction rather than by the find-and-replace above.*

[Delete the Python door](053-delete-the-python-door.md) renamed
`skills/using-passenger-csharp` to `skills/using-passenger`, the address the
deleted Python skill held. The four server strings were never edited and are now
correct:

    src/Passenger.Cli/Program.cs:65
    src/Passenger.Mcp/Program.cs:57
    src/Passenger.Mcp/Tools.cs:17, 94, 107

Decision 1 is therefore moot -- there is one door, so naming its skill cannot
send anyone to the wrong one, and the agent keeps the searchable string. The
paths in the Question are stale in a second way: `dotnet/` is gone from every
one of them, the tree having moved to the repository root in the same commit.

What did **not** close with it, and is live elsewhere:

- The three convergent findings (decision 2) -- filesystem sharing,
  `largestImageSrc` naming a different asset than the visible `<img src>`, and
  the recipe's own silent failures. The first is now stated outright in
  `skills/using-passenger/SKILL.md` ("The server runs on your machine, in your
  filesystem"). The other two are not, and the map's Fog entry on the skill eval
  carries them.
- Decision 3 answered itself: the Python skill is deleted, so it was left to die
  as it was.
- The asymmetry section is history. There is one file; `What cannot cross back`
  and the working picture recipe are in it because it is the C# one that
  survived.
