---
id: 068
title: Does a script need a JSON encoder in scope, or is returning the value enough?
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

`skills/using-passenger/references/writing-scripts.md` has carried a paragraph
since before [056](056-utf8-escape-regression.md) closed telling a
script author to build a `JsonSerializerOptions` with
`JavaScriptEncoder.UnsafeRelaxedJsonEscaping` and serialise through it, because
`JsonSerializer.Serialize` escapes every non-ASCII character by default. It
kept coming back at the owner as a thing to remember, which is the smell that
prompted this ticket: an operating rule that has to be re-learned is usually a
missing affordance somewhere else.

The .NET half of it is settled and needs no research: **there is no global
switch.** `JsonSerializerOptions.Default` is a frozen singleton, and there is
no AppContext switch, environment variable or assembly attribute that changes
the default encoder process-wide. An options instance has to be handed to every
call that wants relaxed escaping. So the paragraph was not documenting a
workaround for something configurable.

What it *was* documenting, though, is a case that mostly should not arise here.
056 already set `UnsafeRelaxedJsonEscaping` on both halves of the wire
(`src/Passenger.Mcp/Program.cs:54` -- the tool's content block and the JSON-RPC
envelope), and `Ran.Returned` is `object?` (`src/Passenger/Service.cs:87`), so a
script that returns a list or a dictionary is encoded by those options and never
touches the default. `Script.Crossable` (`src/Passenger/Script.cs:183`) does
call `JsonSerializer.Serialize(value)` with no options, but only as a
throwaway can-this-cross check -- those bytes are discarded, and escaping is
not an error, so the default encoder there is invisible.

Walking every way a script can meet JSON:

- **Returning structured data** -- return the object; the wire encodes it.
  Serialising first is strictly worse, because the caller then gets JSON inside
  a JSON string to unwrap *and* pays the `\uXXXX` inflation.
- **Returning a string the page built** with `JSON.stringify`, which is what
  the `EvalOnSelectorAllAsync<string[]>` advice in the same file recommends --
  fine as it stands. JS does not escape non-ASCII.
- **Passing data into a page** as an `EvaluateAsync` argument -- Playwright
  serialises that itself, over its own wire, and the script never sees options.
- **Writing a JSON file to disk** -- the only live case. Those bytes are the
  script's own and nothing downstream re-encodes them, and `SKILL.md:125`
  actively pushes callers there ("`File.WriteAllTextAsync` and return the path
  and the length instead"). A `.json` file full of `中文` is the
  script's doing and stays that way.

The reference has been rewritten on that basis: lead with "return the value,
not JSON of it", and keep the encoder as a one-liner scoped to writing a file.
That is the interim answer, and it is already in the tree.

**What is open** is whether the remaining case earns an affordance. The cheap
move is a second member on `ScriptGlobals` (`src/Passenger/Script.cs:39`) --

    public JsonSerializerOptions Json { get; } = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

-- after which the reference collapses to `JsonSerializer.Serialize(x, Json)`
and there is nothing left to re-learn. Against it: ticket 004 settled that the
script surface is `Page` and nothing else, and 046 removed `read` from beside
it for being this project's judgement in the caller's scope. `Json` is not
judgement -- it is an encoder setting with one correct value -- but it is still
a second name, and the argument that it is *only* a convenience is the same
argument every second name arrives with.

Worth answering with a measurement rather than taste: how often does a script
actually write a JSON file? If the answer is "the skill recommends disk for
long text and pictures, and neither of those is JSON", the affordance is for a
case that does not happen and the prose is enough.

## Answer

**No encoder in scope. The encoder was never the problem.**

Two of the three things tangled together here turned out not to be bugs at
all, and the one that was is somewhere else entirely.

**What the owner was actually seeing.** Not our escaping: the site's. Baidu's
tieba search API answers with its non-ASCII written escaped -- a normal,
valid way to spell 中文 -- and the scripts hitting it were pulling fields out
of the raw body with `Regex.Matches` rather than parsing it. A regex hands
back the spelling; a JSON parser hands back the characters. Confirmed both
ways against the live endpoint: the same request read with `JsonDocument` and
`GetString()` returns `["Wei：对我来说，打野就像美食节目一样", ...]`, clean.
The tell in the original script was a hand-rolled `Regex.Unescape` on a
captured field.

Nothing on this side can fix that and nothing on this side should try: a
returned string is the caller's payload, and a tool that quietly decodes what
looks like an escape is interpreting it -- the line this repo does not cross,
and it would corrupt any string legitimately containing a backslash-u.

**So the fix is a rule, not a feature.** `writing-scripts.md` gained "parse a
site's JSON -- do not fish text out of it with a regex", with the parse shown
and both tells named (`Regex.Unescape`, and `RootElement.ToString()`, which
re-escapes on the way out). One claim was cut from that entry before it
shipped because it did not survive being run: `Regex.Unescape` does *not*
throw on `\/`, which JSON allows -- it returns `a/b`. What replaced it is a
real and verified failure that has nothing to do with escaping at all, which
is that `"title":"(.*?)"` truncates silently at the first escaped quote
inside the field.

The disk footnote stays a footnote, per the owner: kept, scoped to writing a
JSON file, and not promoted into `SKILL.md`.

**And `ScriptGlobals` gains nothing.** The case it would have served -- a
script serialising to disk -- is still one no recipe in this repo performs,
and it is now clear it was never the case anyone was hitting. Ticket 004's
one-name surface stays one name.

**One real bug fell out of checking the claims**, and it is [070](070-astral-still-escapes.md):
056's encoder leaves ordinary CJK alone but still escapes anything above
`U+FFFF`, so emoji and rare Han (the kind that appear in Chinese names and
place names) come back as `\uD83D\uDE00` even when returned directly. That is ours,
it is not the SDK, and it is filed rather than fixed here.

Also corrected while here: an earlier line of this ticket claimed
`044-acceptance-set.md` could serve as a scripting-task benchmark for
[069](069-powershell-instead-of-csharp.md). It cannot -- it is five web pages
with extraction diagnostics. 069 now says so and carries building a real task
set as its first job.
