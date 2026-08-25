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
      "a tool result is JSON, so a cycle or a BigInt cannot travel -- return " ++
      "the part you wanted instead",
    ),
  })

// --- what may cross ---------------------------------------------------------

/// A tool result is JSON, and that is the whole rule.
///
/// There used to be twenty-five lines here that refused a live Playwright handle
/// by name, and they were a C# inheritance rather than a fact about this
/// runtime. On that side `System.Text.Json` walked a handle's live object graph
/// and emitted something large and answer-shaped -- the bug ticket 013 exists
/// for, where `return await Page.APIRequest.GetAsync(url)` handed back the
/// driver's own headers and timings as if they were the body. So the type had to
/// be refused before serialisation was attempted.
///
/// Playwright's JavaScript client ships `toJSON` on those objects, so the same
/// mistake is small and self-labelling here. Measured:
///
///     Page            64 B   {"_type":"Page","_guid":"page@a5f77e…"}
///     Locator        117 B   {"_apiName":"Locator","_frame":{…},"_selector":"body"}
///     ElementHandle   75 B   {"_type":"ElementHandle","_guid":"handle@b789b8…"}
///     APIResponse    945 B   {"_apiName":"APIResponse","_request":{…},…}
///
/// Nobody mistakes `_apiName: APIResponse` for their data, and the rule that
/// caught it could not be exact: it tested for a `_guid` or an `_apiName` on the
/// value or one level inside it, so a site whose own JSON carries a field called
/// `_guid` would have had its data refused instead. Guessing wrong about a
/// caller's payload is the worse failure, and it is the one this side is least
/// entitled to make -- the tool measures, the caller judges.
///
/// What is left is the failure that is genuinely not JSON: a cycle, a BigInt.
/// `undefined` is not one of them -- a script with no `return` said nothing, and
/// nothing crosses as null.
let crossable = value => {
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

/// Whatever was thrown, said in one line.
///
/// `throw` takes any value in JavaScript, and four ways of using it -- `throw 42`,
/// `throw null`, `throw {why: '...'}`, `Promise.reject('boom')` -- carry no
/// `name` and no `message`. Reading those two fields and defaulting both
/// produced `"Error:"` and nothing else, which told a caller precisely nothing
/// about their own script. So a value with no message is *shown* instead.
///
/// There is no stack on any of them either, so `where` is empty and honestly so:
/// a value thrown without an Error never recorded where it came from.
let described = e => {
  let message = JsExn.message(e)->Option.getOr("")
  if message != "" {
    `${JsExn.name(e)->Option.getOr("Error")}: ${message}`
  } else {
    switch JSON.stringifyAny(e) {
    | Some(json) => `threw ${json}`
    | None => `threw ${e->Obj.magic->String.make}`
    | exception _ => `threw ${e->Obj.magic->String.make}`
    }
  }
}

let raised = (e, source) =>
  Errors.Passenger({
    code: ScriptRaised,
    message: described(e)->String.split("\n")->Array.getUnsafe(0)->String.trimEnd,
    detail: Some(where(JsExn.stack(e)->Option.getOr(""), source)),
  })

/// What a script sees.
///
/// `Page` and a short list beside it, which is this runtime's answer to the C#
/// door's `Imports`. A vm context starts with V8's intrinsics -- JSON, Math,
/// Promise, Object -- and none of Node's host objects, so anything a recipe in
/// the skill reaches for has to be put here by name.
///
/// The list is what those recipes need and stops there. `console` because a
/// script's own tracing has to go somewhere, and **it is rebuilt so that all of
/// it goes to stderr**. Handing the real `console` over looked right and was
/// not: `console.log` writes to stdout, which is the JSON-RPC transport, so one
/// tracing line in a caller's script corrupted the stream it was travelling on.
/// Measured after the fact -- the comment here claimed stderr for a while before
/// the code did.
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
/// Every method on it, pointed at stderr. Not a subset: a script reaching for
/// `console.table` or `console.dir` must not be the one that breaks the wire.
let quietConsole: 'a = %raw(`(() => {
  const out = {};
  for (const name of Object.keys(console)) {
    out[name] = typeof console[name] === "function"
      ? (...args) => console.error(...args)
      : console[name];
  }
  return out;
})()`)

@module("node:fs/promises") external fs: 'a = "default"
@module("node:path") external path: 'a = "default"
@val external setTimeout_: 'a = "setTimeout"
@val external clearTimeout_: 'a = "clearTimeout"

let globals = page => {
  "Page": page,
  "console": quietConsole,
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
