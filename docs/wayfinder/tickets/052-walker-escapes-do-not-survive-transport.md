---
id: 052
title: walker.js carries \u escapes that do not survive transcription
labels: [wayfinder:task]
status: open
assignee:
blocked_by: []
---

## Question

Two lines of `walker.js` put `\u` escapes inside **regex literals**:

    196:  for (const line of raw.split(/\r\n|[\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029]/)) {
    205:  const text = line.replace(/[ \t\u00a0]+/g, ' ').trim();

The skills tell an agent to read the file and paste its contents into a script.
That path crosses a JSON tool boundary, and a JSON string decodes `\u2028` to
the actual character. U+2028 and U+2029 are **line terminators in JavaScript**,
so a literal one inside a regex literal ends the literal early. The browser then
reports:

    SCRIPT_RAISED: SyntaxError: Invalid regular expression: missing /

Measured in a skill eval: the C# with-skill run on
`https://peps.python.org/pep-0008/` **burned its first two `script` calls on
this**, re-pasting the walker in between because the advice it had been given
said transcription was the risky part. It recovered by rebuilding both regexes
with `new RegExp('...')` from ASCII-only strings — which is the fix, at the
source, for everyone.

The Python with-skill run on the same page did not hit it. So this reproduces
at one door and not the other, which is why it reads as a language problem and
is not one: the escapes are hostile to *being transcribed at all*, and the C#
recipe simply transcribes more of the file more literally.

### Why the C# skill's existing advice does not cover it

`using-passenger-csharp` already has a paragraph about pasting the walker:

> **Paste it inside a raw string literal (`"""`), not a `@"..."` one.** The
> walker contains quotes; a verbatim string would need every one of them
> doubled, which is a transcription you will get wrong. A raw literal needs no
> escaping at all, and the walker contains no `"""` sequence for it to collide
> with.

Every sentence is true and the conclusion — *a raw literal needs no escaping at
all* — is the one that misleads, because it is about C# lexing and the failure
is downstream of it, in JSON. An agent that follows this advice exactly still
gets a `SyntaxError`, and has been told in advance that the thing it just did
correctly was the hazard. That is worse than silence: it spends the agent's next
call re-doing the step that was already right.

### To decide

1. **Fix it at the source.** Replace the two regex literals with `new RegExp`
   over ASCII-only strings (`'\\u2028'` in a string is inert under JSON decode
   because the backslash is escaped). This makes the walker transport-safe by
   construction and needs no paragraph in either skill. Costs two slightly less
   readable lines in a file that is otherwise deliberately literal, and the
   comment on line 188 explaining the U+00A0 choice has to move with it.
2. **Say it in the skills instead.** Cheaper in code, but it is a fact about
   *transcription*, which means it is true at both doors and would be written
   twice — the drift [026](026-one-description-two-doors.md) is about, and the
   thing [049](049-skill-for-the-csharp-door.md) accepted as the cost of two
   skills. It also cannot be stated crisply: "the escapes survive C# but not
   JSON" is a sentence about a boundary the agent cannot see.
3. **Both**, if the walker keeps any `\u` escape at all after (1).
4. **Fix the misleading sentence in `using-passenger-csharp/SKILL.md`
   regardless of (1)–(3).** The raw-literal paragraph's claim — *"a raw literal
   needs no escaping at all"* — is true about C# lexing and false about the
   outcome, which is what made the C# with-skill run trust the step that had
   just sent it into the failure. That sentence is a general claim about `"""`
   literals, not scoped to whether the pasted content happens to contain a
   `\u2028`-style escape, so it stays wrong for the next thing pasted through
   it even after the walker itself is patched. Not blocked by whether (1)
   ships: soften the claim to say a raw literal is safe from C#'s own quoting
   rules, and name the separate JSON-transport hazard as its own sentence
   rather than folding it into "no escaping at all".

Option 1 looks right, and there is a test-shaped version of it: a walker that
survives a JSON round trip is a property `tests/test_walker.py` could assert
directly, and nothing currently does. [034](034-broken-walker-passes-its-tests.md)
is the precedent for the suite being green over a walker that does not work.
Option 4 is independent of which of 1–3 is chosen and should land either way.

### Coupling

`walker.js` is byte-identical across both skill directories and
[049](049-skill-for-the-csharp-door.md) requires it stay that way, so any fix is
two files plus the test. Same coupling as
[051](051-walker-strips-asides.md), and the two touch adjacent lines (196/205
here, 20 there) — worth doing together rather than twice.

### What the same eval says about the walker's standing

Four runs read PEP 8 into markdown: both doors, with and without the skill. The
two **baseline** runs had no access to `walker.js` at all and wrote their own
extractor in-page. They did not do worse.

| run | `script` calls | rework | output | absolute links |
|---|---|---|---|---|
| py + skill | 4 | 2 | 46 KB | 23 |
| py baseline | 3 | 2 | 52 KB | 77 |
| C# + skill | 4 | 2 failed + 1 | 46 KB | 23 |
| C# baseline | 4 | 2 | 51 KB | 77 |

The link gap is not a defect on either side — the walker strips `nav`, so the
table of contents goes with it, while a hand-rolled extractor kept it and
resolved every anchor to an absolute URL. Both are defensible readings of "keep
the links". What is not defensible is the call count: **the shipped recipe cost
the C# run two hard failures that neither baseline suffered**, and no run that
used the walker beat a run that did not.

Every one of the eight rework calls across these four runs was spent on a
*silent* defect — an `<a>` inside an `<li>` losing its href and turning the
whole ToC into plain text; bare text nodes inside `<aside class="footnote">`
flushed as separate paragraphs and shredding `[2]` into `[`, `2`, `]`; headings
wrapped in `<a class="toc-backref">` coming out as self-referential links. In
all eight the character count looked right and only reading the tail of the
output revealed it. That is the same shape as [051](051-walker-strips-asides.md)
and the same shape as 039's fog entry, arriving now from three independent
directions in one afternoon.

## Two thirds of this went with the Python door

*Recorded 2026-08-24.* [Delete the Python door](053-delete-the-python-door.md)
changed the recipe and the file layout underneath this ticket, and most of what
is above is now about things that do not exist.

- **The skill stopped pasting the walker.** `skills/using-passenger/SKILL.md:124`
  reads it off disk with `File.ReadAllTextAsync`, because the server runs on the
  caller's own machine. The escapes never cross a JSON boundary on that path, so
  the measured failure is unreachable at the only call site the skill ships.
- **Option 4 is done.** The misleading raw-literal paragraph is gone with the
  raw literal. What replaced it names the JSON-transport hazard directly, as its
  own sentence, and says why reading beats pasting.
- **Option 2 is dead.** There is one skill, so the "it would be written twice"
  objection has nothing to be twice.
- **The coupling section is void.** `walker.js` exists once, at
  `skills/using-passenger/walker.js`. `tests/test_walker.py` went with the
  Python suite and nothing replaced it -- see
  [043](043-tidy-hides-walker-differences.md), which is now about the same
  absence.

**What is left is option 1 alone, and it is smaller and weaker.** Lines 196 and
205 still carry the backslash-u escapes for U+2028, U+2029 and U+00A0 inside
regex literals, so the file is still hostile to being pasted -- by an agent that
did not read the skill, or by any future caller with a reason to inline it.
Fixing it at the source with `new RegExp` over ASCII-only strings costs two less
readable lines and makes the paragraph in the skill unnecessary rather than
merely correct. Against that: nothing on the shipped path hits it any more, so
this is now insurance rather than a bug with a reproduction.

The test-shaped version of it has lost its home. There is no walker suite in
`tests/Passenger.Tests/` at all, so "a walker that survives a JSON round trip"
cannot be asserted until [043](043-tidy-hides-walker-differences.md) decides
whether the walker gets tests again.
