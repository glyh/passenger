---
id: 027
title: Whether the payload is AsciiDoc rather than Markdown
labels: [wayfinder:grilling]
status: closed
assignee:
blocked_by: []
---

## Question

Every path out of this tool ends in markdown. `Fetched.markdown` is the
field name, `article_text` asks trafilatura for `output_format="markdown"`,
`_DOM_JS` was taught `#`, `- ` and ``` ``` ``` by
[Whether dom alone is enough](025-whether-dom-alone-is-enough.md), and
[A listing read through dom mode has no link
targets](007-links-lost-in-dom-mode.md) settled `[label](url)` inline. The
question is whether AsciiDoc would be the better payload, and it is a
grilling because the honest first answer is probably "no, and here is what
it would take to change that".

The case for asking at all is that markdown was never chosen here. It
arrived as trafilatura's default and the walker was made to match it. A
format that is picked by default in a tool whose whole output *is* that
format deserves one deliberate look.

The case against is the caller. This payload has exactly one consumer -- an
agent -- and markdown is the format that consumer reads most fluently and
most cheaply. Any argument for AsciiDoc has to beat that, and expressiveness
alone will not, because expressiveness is what
[016](016-the-result-says-what-it-missed.md) and
[019](019-the-tool-does-not-learn.md) both refused to pay for.

To decide:

1. **What a web page holds that markdown cannot carry.** The concrete
   candidates are nested lists that survive a round trip, tables with spans
   or multi-line cells, and a source line on a fenced block. `dom` currently
   indents `LI` two spaces per level and 025 found the marker orphans itself
   when the item's child is a block -- an AsciiDoc `**` marker has no such
   failure mode, being a count rather than an indent. Whether that is a real
   win or a coincidence of the current walker being half-finished is the
   first thing to establish, because fixing the walker is ten lines and
   changing the format is not.

2. **What it costs the reader.** Markdown is overwhelmingly the format an
   agent has seen; AsciiDoc is rare by comparison. A payload the consumer
   parses slightly wrong is worse than one that loses a table span. This is
   not measurable from here without an experiment, and what that experiment
   would even be -- a page read both ways, questions answered off each -- is
   part of the grilling.

3. **Whether it is one emitter or two.** Blocked on 025 for this reason.
   Trafilatura emits markdown, txt, xml and csv, and not AsciiDoc. If
   `article` survives -- which is 025's recommendation, on moonofalabama --
   then AsciiDoc means either converting trafilatura's markdown after the
   fact, which cannot recover what markdown could not express and so buys
   nothing, or two extractors emitting two different formats, which is the
   output contract splitting in half. Only the fork where `dom` is the sole
   mode makes this cheap, and 025 currently says that fork is closed.

4. **The link syntax, which is the one place the two genuinely differ in
   cost.** 007 made links non-negotiable and put them inline, and
   `unlinked` in `ab/text.py` exists because a URL costs a startling number of
   tokens. AsciiDoc spells the same link `https://x[label]` -- the target
   appears once either way, so this is close to a wash, but `_LINK_TARGET`
   and anything else that reads the markup by regex would have to move with
   it. Worth checking whether either syntax is meaningfully cheaper to
   *strip*.

5. **What the field is called.** `Fetched.markdown` is in the JSON contract
   at both doors, in `--json`, and in the README. If the format becomes a
   choice rather than a fact, the field name is a lie and renaming it is a
   breaking change on a par with 021's default -- which argues for deciding
   the format once and hard-coding it, not for a `format` parameter. A
   parameter here would also be a second way to do one thing, which
   [How thin can this layer get](020-how-thin-can-this-layer-get.md) spent a
   ticket removing.

6. **Whether the port cares.** [Whether this moves to
   C#](023-rewriting-into-csharp.md) has to re-emit whatever this decides.
   `dom`'s markup is JavaScript that ships as a string and would port
   untouched either way, so the format is not a C# question -- but if 025's
   second phase happens and trafilatura's core is reimplemented, its output
   format stops being inherited and becomes a choice for the first time.
   That is the one future in which this ticket is cheap, and it is worth
   knowing now rather than discovering there.

A plausible outcome is that the answer is "no, and the real finding is the
`LI` marker bug and the walker's missing tables", in which case this closes
having pointed at work that belongs in 025's markup half. That is a fine
outcome and should not be argued away.

## Two of these are already answered

Both by [025](025-whether-dom-alone-is-enough.md) and the walker fix that
closed with it, and both against AsciiDoc. Recorded so the grilling starts
from the narrowed case rather than re-deriving them.

**Item 1 was a coincidence of a half-finished walker.** The orphaned `LI`
marker is fixed in commit 09e1819: the marker is deferred until the first text
actually lands, so docs.python.org went from 8 bare dashes and 0 usable
bullets to 8 bullets and no orphans. It was ten lines, as this ticket
predicted, and AsciiDoc's `**` counter wins nothing that the indent does not
now also do. Nested lists survive a round trip in both.

**Item 3 is closed by `article` surviving.** 025 kept trafilatura, so this is
the fork where AsciiDoc means either converting trafilatura's markdown after
the fact -- which cannot recover what markdown could not express, and so buys
nothing -- or two extractors emitting two formats, which splits the output
contract in half. The cheap fork is gone.

**What is left is item 2, and item 4 is a wash.** The entire live case for
AsciiDoc is now what the format costs the reader, which this ticket already
says is not measurable from here. Designing that experiment is most of the
remaining work, and the ticket's own prediction -- "no, and here is what it
would take to change that" -- is now the likelier outcome, not less.

## Answer

**No. The payload stays markdown**, and the tool's one consumer is the whole
reason: markdown is what an agent reads most fluently and most cheaply, and
this ticket set the bar that expressiveness alone would not beat it.

Nothing was left to weigh. Item 1 was a coincidence of a half-finished walker
and cost ten lines to fix. Item 3 closed with `article` surviving
[025](025-whether-dom-alone-is-enough.md), which removes the only fork where
AsciiDoc was cheap. Item 4 was a wash by this ticket's own reading. That
leaves item 2 -- what the format costs the reader -- which is the one
consideration that was never measurable from here, and it points the same way
the other three do.

The deliberate look this ticket was created to force did happen: markdown
arrived as trafilatura's default and has now been kept on purpose.

Unexamined, and deliberately not carried forward as a ticket: nothing has
measured how an agent actually reads either format, and no experiment for it
was designed. Revisit only if the format is ever implicated in a caller
misreading a page. [One extractor instead of
two](029-one-extractor-instead-of-two.md) inherits markdown as settled rather
than as an open axis.
