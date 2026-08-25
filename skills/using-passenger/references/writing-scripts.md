# Writing the C#

`SKILL.md` has the three that stop a script compiling at all -- `Page`
capitalised, everything awaited, top-level `return` is fine. These are the
rest, and none of them are about the page.

## The ones that bite once

**Wrap JavaScript in a verbatim string, `@"..."`.** In an ordinary C# string
`\n` is a real newline, so a snippet carrying `.split('\n')` reaches the page as
a broken literal and comes back as `SyntaxError: Invalid or unexpected token`
or `Invalid regular expression: missing /` -- which reads like the page's fault
and is not. Inside `@"..."` a backslash stays a backslash; write double quotes
as `""`, or sidestep them by quoting JS strings with `'`. This is the same
hazard as pasting `markdown.js` instead of reading it off disk, one size
smaller.

**Split a nested `await` at the top level.** As a top-level statement,
`await (await Page.APIRequest.GetAsync(url)).TextAsync()` fails to compile with
`The name 'await' does not exist in the current context`, and the line number
points at the *next* line. Two statements always work:

    var response = await Page.APIRequest.GetAsync(url);
    var body = await response.TextAsync();

**Guard every property read on the JS side.** `.innerText` on an element that
is not there throws `Cannot read properties of undefined`, and that takes down
the whole script as `SCRIPT_RAISED` -- one missing node and you get nothing
instead of the other nineteen rows. Write `(el || {}).innerText || ''`.

**Local functions go before the `return`.** A helper you want to call from a
top-level `return` is a local function declared earlier in the same source.
Still no class and no method wrapper.

**Say the type on `EvalOnSelectorAllAsync<T>`.** It is required, and forgetting
it is the single most common way this call fails. There is an overload without
it, so the compiler will not always save you: it returns `JsonElement`, which
crosses the boundary as a shape you did not intend. For more than one field per
element, `<string[]>` with each element `JSON.stringify`d survives more
reliably than an array of objects.

**Navigating again mid-script destroys the context.** Evaluating after a
`GotoAsync` that itself followed an evaluation raises `Execution context was
destroyed, most likely because of a navigation`. Put the `GotoAsync` inside the
per-item helper and wait once after it before reading.

**`timeoutSeconds` is a budget per Playwright operation, not per script.** It
defaults to 60, so a script doing thirty scroll rounds is nowhere near it while
a single screenshot of a tall page can be. Raise it on the call that contains
one slow operation, not on the call that contains many quick ones.

**A missing `tab` does not fail -- it answers.** Omit `tab` and you get a fresh
blank page, and the script runs happily against `about:blank` and returns
zeroes and empty strings indistinguishable from a page with nothing on it. Pass
the `tab` from the previous reply when you are continuing one. The opposite
mistake is loud: a tab that has since been closed throws `TargetClosedError`,
and the fix is to navigate again without it.

**Return the value, not JSON of it.** What you return crosses as JSON either
way, and the server writes those bytes with an encoder that leaves non-ASCII
alone -- so `return results;` hands back a list or a dictionary as itself.
Serialising it first buys nothing and costs twice: the caller gets JSON inside
a JSON string to unwrap, and `JsonSerializer`'s default encoder escapes every
non-Latin character to a 6-byte `\uXXXX`, which on a page full of CJK is most
of the payload. A string the *page* built with `JSON.stringify` is safe to
return as it stands -- JS does not escape non-ASCII.

The one place you serialise yourself is a JSON *file*. Those bytes are yours
and nothing downstream re-encodes them, so pass the encoder there:

    var opts = new JsonSerializerOptions {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };
    await File.WriteAllTextAsync(path, JsonSerializer.Serialize(results, opts));

## What cannot cross back

A tool result is JSON, and nearly every Playwright call hands back a live
handle that is not. Returning an `ILocator` or an `IElementHandle` is refused
by name with `SCRIPT_RETURN_NOT_JSON` -- return what you wanted *from* it
instead:

    return Page.Url;                                  // not Page
    return await Page.Locator("h1").InnerTextAsync(); // not the locator

`Page.APIRequest.GetAsync` is the same trap wearing different clothes: it hands
back an `IAPIResponse`, which is a live handle. Returning it is refused, and
until this skill was written it was worse than refused -- it serialised the
driver's headers and timings and handed them back looking like an answer. Ask
it for `BodyAsync()` or `TextAsync()` and return that.

## Do not restructure a script to avoid the compile

Measured: after the server's first call, compiling a script costs a flat ~40ms
whatever it says -- an 11 KB source carrying the whole of `markdown.js`
compiles in the same time as a one-line one. It is noise beside a single
navigation, and batching unrelated work into one script to amortise it buys
nothing while costing you the ability to continue from where a failure left
off.
