// Functional core, almost: turning caller-supplied source into a value.
//
// The one door onto the browser is a script, not a tool per verb (ticket 004),
// so this module owns the two things that door needs: getting the source to run
// with `return` in it, and deciding what may come back out.
//
// Nothing here touches a browser. It is handed a page by the shell and never
// learns what it is, which is what makes it testable without one.
//
// **The one place the port changes the caller's contract, again.** The source
// was Python, then C# on Roslyn, and is JavaScript on `node:vm` here. The shape
// of the door is unchanged: one name is bound, `return` hands a value back, and
// what may cross is still JSON and nothing else. What the caller writes is
// `await Page.goto(url)` where the C# door wanted `await Page.GotoAsync(url)` --
// camelCase because a Playwright member in this runtime is camelCase, which is
// the same reasoning that made it PascalCase there.
//
// Two costs the C# door paid are simply gone. There is no compile step to warm
// (`Script.Warm`, several hundred milliseconds on the first Roslyn create) and
// no flat ~40ms per script; `new vm.Script` is V8 parsing a string. And a
// `SyntaxError` still arrives before the browser is touched, which is what
// ticket 023 wanted from Roslyn.

/// The name a caller's lines are reported against, matching the Python and C#
/// doors' `"<script>"`. It is what `where` filters a stack trace on.
let scriptPath = "<script>"

/// One line of the caller's source, trimmed, or "" if out of range.
let lineOf = (source, number) => {
  let body = source->String.trim->String.split("\n")
  number >= 1 && number <= body->Array.length
    ? body->Array.getUnsafe(number - 1)->String.trim
    : ""
}

let notJson = what =>
  Errors.Passenger({
    code: ScriptReturnNotJson,
    message: `a ${what} cannot cross the tool boundary`,
    detail: Some(
      "return what you wanted from it instead -- Page.url(), " ++
      "await locator.innerText(), a list of hrefs",
    ),
  })

// --- what may cross ---------------------------------------------------------

// A rule rather than a list, and the list is what it replaced on the C# side:
// eight types were named by hand there and `IAPIResponse` was not among them, so
// `return await Page.APIRequest.GetAsync(url)` serialised the driver's own
// headers and timings and handed them back as if they were the answer.
//
// The rule there was "implements a Playwright interface". This runtime has no
// interfaces, so the rule is measured off the objects instead. Every handle in
// Playwright's client is one of three shapes, and all three were checked against
// a live browser:
//
//   * a ChannelOwner -- Page, Frame, ElementHandle, JSHandle, BrowserContext,
//     Browser, APIRequestContext, Tracing and the rest. It carries a string
//     `_guid`, and it serialises to `{"_type":"Page","_guid":"page@..."}`, which
//     is worse than a failure: it succeeds, and hands back Playwright's internal
//     identity in the shape of an answer.
//   * a Locator or an APIResponse, which are *not* ChannelOwners and carry no
//     `_guid`. Both carry a string `_apiName`, and APIResponse serialises to its
//     `_initializer` -- the exact failure the C# comment above describes.
//   * a Keyboard, Mouse, Touchscreen, FrameLocator, Clock or Coverage, which
//     carry neither but hold a ChannelOwner in a field of their own.
//
// Hence three tests, and the third is one level deep on purpose: a handle
// cannot get inside a plain object except by a caller putting it there, which is
// the same mistake one layer down, and a deeper walk would start refusing a
// caller's own data for containing a string called `_guid`.
//
// Property reads rather than `instanceof`, and that is load-bearing: a vm
// context is its own realm, so a value built inside a caller's script has a
// different `Object` and `Array` than this module does. `typeof` and a field
// read cross realms; a constructor check does not.
let isObject: 'a => bool = %raw(`v => v !== null && typeof v === "object"`)
let stringField: ('a, string) => option<string> = %raw(`(v, k) => {
  const got = v[k];
  return typeof got === "string" ? got : undefined;
}`)
let fields: 'a => array<'b> = %raw(`v => { try { return Object.values(v); } catch (e) { return []; } }`)

/// The name to report a refused value by, when it is a handle. `None` if it is
/// not one.
let handleName = value =>
  if !isObject(value) {
    None
  } else if stringField(value, "_guid")->Option.isSome {
    // `constructor.name` is minified in the shipped bundle (`_Page`, `Browser2`),
    // so the `_type` Playwright puts in its own serialisation is the more
    // readable of the two names it offers, and the more stable.
    Some(stringField(value, "_type")->Option.getOr("Playwright handle"))
  } else if stringField(value, "_apiName")->Option.isSome {
    stringField(value, "_apiName")
  } else if
    fields(value)->Array.some(f => isObject(f) && stringField(f, "_guid")->Option.isSome)
  {
    Some("Playwright handle")
  } else {
    None
  }

/// A tool result is JSON. Playwright hands back handles, which are not.
///
/// Checked by shape before serialisation is attempted, because a handle is a
/// live object that `JSON.stringify` will not refuse -- it would not throw, it
/// would emit Playwright's guid or its initializer. That is the runtime-specific
/// half of this check, and it is the same half the C# door had to write by hand.
let crossable = value => {
  switch handleName(value) {
  | Some(what) => throw(notJson(what))
  | None => ()
  }

  // `undefined` is not an error: a script with no `return` said nothing, and
  // nothing crosses as null.
  switch JSON.stringifyAny(value) {
  | _ => ()
  | exception _ => throw(notJson("value"))
  }

  value
}

// --- compiling and running --------------------------------------------------

/// Compile, reporting a syntax error against the caller's own line numbers.
///
/// The line needs no offset: the async IIFE `Node.wrap` puts round the source
/// carries no newline before the body, so line 1 is still line 1. V8 puts the
/// line on the *first* line of the stack -- `<script>:1` -- rather than in the
/// message, which is where this reads it from.
let compile = source =>
  switch Node.script(Node.wrap(source), {"filename": scriptPath}) {
  | compiled => compiled
  | exception JsExn(e) =>
    let line =
      JsExn.stack(e)
      ->Option.flatMap(stack => stack->String.match(RegExp.fromString(`^${scriptPath}:(\\d+)`)))
      ->Option.flatMap(m => m->Array.get(1)->Option.getOr(None))
      ->Option.flatMap(n => Int.fromString(n))
      ->Option.getOr(1)
    throw(
      Errors.Passenger({
        code: ScriptInvalid,
        message: `${JsExn.message(e)->Option.getOr("could not be parsed")} (line ${line->Int.toString})`,
        detail: Some(lineOf(source, line)),
      }),
    )
  }

/// The script's own lines out of a stack trace that also holds this file.
///
/// Reported against the source the caller sent, not the machinery it was run
/// in, so the line numbers are the ones they can see.
///
/// One frame is always dropped: the IIFE's own closing `})()` sits one line past
/// the end of the caller's source, so V8 reports the call itself as a frame the
/// caller did not write. A line number past the end of the source is that
/// wrapper and nothing else, since the wrapper adds exactly one line.
let where = (stack, source) => {
  let last = source->String.trim->String.split("\n")->Array.length
  let frames = []
  stack
  ->String.split("\n")
  ->Array.forEach(frame =>
    switch frame->String.match(RegExp.fromString(`${scriptPath}:(\\d+):`)) {
    | Some(m) =>
      switch m->Array.get(1)->Option.getOr(None)->Option.flatMap(n => Int.fromString(n)) {
      | Some(number) if number >= 1 && number <= last =>
        frames->Array.push(`line ${number->Int.toString}: ${lineOf(source, number)}`)
      | _ => ()
      }
    | None => ()
    }
  )
  frames->Array.join("\n")
}

let raised = (e, source) => {
  let name = JsExn.name(e)->Option.getOr("Error")
  let message = JsExn.message(e)->Option.getOr("")
  Errors.Passenger({
    code: ScriptRaised,
    message: `${name}: ${message}`->String.split("\n")->Array.getUnsafe(0)->String.trimEnd,
    detail: Some(where(JsExn.stack(e)->Option.getOr(""), source)),
  })
}

/// What a script sees.
///
/// `Page` and a short list beside it, which is this runtime's answer to the C#
/// door's `Imports`. A vm context starts with V8's intrinsics -- JSON, Math,
/// Promise, Object -- and none of Node's host objects, so anything a recipe in
/// the skill reaches for has to be put here by name.
///
/// The list is what those recipes need and stops there. `console` because a
/// script's own tracing has to go somewhere, and it goes to stderr where every
/// other line of this process's chatter goes -- stdout is the protocol.
/// `fs`/`path` for the same reason the C# door imported `System.IO`: the walker
/// and the picture measurement are read off disk, and bytes that cannot cross
/// back as JSON are written out. Timers because a script that needs to wait
/// without a page in hand has nothing else.
///
/// **`fetch` is deliberately not here.** It would be a second way onto the web
/// that goes around the browser entirely -- no cookies, no session, none of what
/// this tool exists for -- and ticket 046 deleted exactly that. `Page.request`
/// is the sanctioned one, and it goes through the browser's own context.
///
/// Deliberately not a sandbox, and not pretending to be one: a caller-supplied
/// script runs in this process either way, and what is missing here is still
/// reachable by other means.
@val external console: 'a = "console"
@module("node:fs/promises") external fs: 'a = "default"
@module("node:path") external path: 'a = "default"
@val external setTimeout_: 'a = "setTimeout"
@val external clearTimeout_: 'a = "clearTimeout"

let globals = page => {
  "Page": page,
  "console": console,
  "fs": fs,
  "path": path,
  "setTimeout": setTimeout_,
  "clearTimeout": clearTimeout_,
}

/// Run the script and return what it returned, checked.
///
/// Raises for the three ways this goes wrong -- source that will not parse, a
/// script that threw, and a value that cannot leave -- each naming which one it
/// was, since the caller's next move differs for each.
let execute = async (source, page) => {
  let compiled = compile(source)
  let context = Node.createContext(globals(page))
  switch await compiled->Node.runInContext(context) {
  | returned => crossable(returned)
  | exception JsExn(e) => throw(raised(e, source))
  }
}
