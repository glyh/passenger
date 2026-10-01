---
id: 070
title: 056's encoder still escapes emoji and rare Han
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

[056](056-utf8-escape-regression.md) put `JavaScriptEncoder.UnsafeRelaxedJson`
`Escaping` on both halves of the wire and closed. It fixed what it was opened
for -- ordinary CJK crosses as itself -- but it does not cover everything
above the Basic Multilingual Plane. Measured today against the running
build, from a script that returns a dictionary directly, with no
serialisation and no regex on the caller's side:

    "bmp":          "中文"                        correct
    "emoji_direct": "\uD83D\uDE00 \uD83D\uDE80"    should be 😀 🚀
    "astral_han":   "\uD842\uDFB7"                 should be 𠮷

So a character written with a surrogate pair still costs 12 bytes on the wire
where UTF-8 writes 4, which is 056's own argument, unfinished.

**It is not the SDK.** That was the first theory and it is wrong. Serialising
the same value three ways inside a script settles it:

    default      {"s":"\uD83D\uDE00\u4E2D"}
    relaxed      {"s":"\uD83D\uDE00中"}
    ranges_all   {"s":"\uD83D\uDE00中"}

`UnsafeRelaxedJsonEscaping` escapes the emoji itself, in this runtime, while
leaving 中 alone -- identically to `Create(UnicodeRanges.All)`. The built-in
encoders' allow-lists are expressed as `UnicodeRange`s, and a `UnicodeRange`
cannot describe anything above `0xFFFF`, so a scalar outside the BMP is
outside every allow-list there is. Nothing in `Program.cs` or in the fork is
choosing this; it is what the encoder does.

**What it would take** is therefore a custom `JavaScriptEncoder` rather than a
different built-in one -- overriding `WillEncode` and
`FindFirstCharacterToEncode` to pass surrogate pairs through, with the
relaxed behaviour kept for everything else. That is more than a settings
change, which is why this is its own ticket and not an amendment to 056.

**Whether it is worth doing** is the real question, and the honest case
against is that this is valid JSON either way: every parser decodes
`\uD83D\uDE00` back to the emoji, so nothing is lost or corrupted, and a
client rendering the reply shows the right character. The cost is bytes and
transcript readability. The case *for* is that 056's argument was exactly
those two things, and that rare Han is not a novelty here -- it turns up in
Chinese personal and place names, which is squarely what this tool gets
pointed at.

Found while writing up [068](068-json-encoder-in-scope.md), by checking a
claim rather than trusting it: `writing-scripts.md` says the server "writes
those bytes with an encoder that leaves non-ASCII alone", which is now known
to be true only below `U+10000`. That sentence needs trimming whichever way
this ticket goes.

## Answer

**Moot by the port, and the one surviving item is resolved by it too.** Nothing
here is a fix; the premise died with the C# tree.

There is no `Program.cs`, no `JavaScriptEncoder` and no
`UnsafeRelaxedJsonEscaping` anywhere under `src/` or `skills/` -- the tree was
deleted in `6488cc8` ("Close 071: delete the C# implementation"). The wire is
now `JSON.stringify`, called in exactly two places that matter:
`src/cli/Main.res:117` (`let json = value => text(JSON.stringify(value,
~space=0))`) and `src/core/Script.res:78` (`JSON.stringifyAny`). Node's
serialiser has no UnicodeRange allow-list to be outside of, so the whole
mechanism this ticket diagnosed -- *"a UnicodeRange cannot describe anything
above 0xFFFF, so a scalar outside the BMP is outside every allow-list there
is"* -- no longer exists. Measured, on this machine:

    $ node -e 'process.stdout.write(JSON.stringify({emoji:"\u{1F600}",han:"\u{20BB7}"})+"\n")'
    {"emoji":"\u{1F600}","han":"\u{20BB7}"}    (literal emoji and literal \u{20BB7})

The three escapes the ticket measured -- `\uD83D\uDE00`, `\uD83D\uDE80`,
`\uD842\uDFB7` -- are no longer emitted by any path.

**And the sentence this ticket left open needs no trim after all.** Its last
paragraph says `writing-scripts.md`'s claim "is now known to be true only below
`U+10000`", so *"that sentence needs trimming whichever way this ticket goes"*.
It was not trimmed; it reads today, at
`skills/using-passenger/references/writing-scripts.md:169`:

> Nothing on this path escapes non-ASCII: CJK and emoji cross as themselves,
> in both directions.

Under the C# encoder that sentence was an overclaim, and this ticket is where
that was found. Under `JSON.stringify` it is simply true -- above `U+10000`
included, as the measurement above shows. The sentence and the code agree for
the first time, by the code changing rather than the sentence. Verified here
rather than assumed: the first reading of this ticket left it "unverified
which way it went", and it went the right way.

Closed with no code change. [068](068-json-encoder-in-scope.md) and
[056](056-utf8-escape-regression.md) remain closed and are now history about
deleted code, which `071`'s map entry already says.
