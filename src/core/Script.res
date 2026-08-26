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
// of the door is unchanged where it counts: `Page` is bound, `return` hands a
// value back, and what may cross is still JSON and nothing else. What *is*
// different since ticket 074 is how much else is in scope -- everything this
// process has, because this process is the caller's own machine. What the caller writes is
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

/// The names the wrapper takes, in the order `execute` applies them.
///
/// A list rather than a record now: they are the parameters of an async
/// function, so their spelling here and their order there have to agree, and
/// one array is the only place that is true.
let bound = ["Page", "console", "fs", "path", "require"]

/// Compile, reporting a syntax error against the caller's own line numbers.
///
/// The line needs no offset: the async wrapper `Node.wrap` puts round the source
/// carries no newline before the body, so line 1 is still line 1. V8 puts the
/// line on the *first* line of the stack -- `<script>:1` -- rather than in the
/// message, which is where this reads it from.
let compile = source =>
  switch Node.script(Node.wrap(source, ~names=bound), {"filename": scriptPath}) {
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
/// One frame is always dropped: the wrapper's own closing `})` sits one line past
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
/// **Everything this process sees, plus `Page`.** Since ticket 074 the source
/// runs in *this* context rather than a fresh `vm` one, so `fetch`, `URL`,
/// `Buffer`, `process`, the timers and every other Node global are simply
/// there, because they are there for this file too.
///
/// That is a reversal of two rules and it is worth being plain about both.
/// There was a list here -- `Page`, `console`, `fs`, `path`, and the two timers
/// -- and `fetch` was left off it by name, from ticket 046, on the grounds that
/// a second way onto the web going around the browser has none of the cookies
/// and none of the session this tool exists for. That reasoning is still true
/// about *the design*: `Page.request` is the sanctioned way onto the web and a
/// recipe that reaches for `fetch` instead has misunderstood the tool. What was
/// never true is that leaving the name out *enforced* anything. This file's own
/// header said so -- "deliberately not a sandbox, and not pretending to be one:
/// a caller-supplied script runs in this process either way, and what is
/// missing here is still reachable by other means." A name that a determined
/// script could reach through `process.binding` or a `require` away was
/// stopping an accident, at the price of a real one: a caller with a legitimate
/// need for a Node global got a `ReferenceError` and no way round it.
///
/// **passenger runs on the caller's own machine**, launched by their own agent,
/// against their own logged-in Chrome. There is nobody on the other side of
/// that wall to keep out, which is the whole of ticket 074's argument.
///
/// Four names are still handed in, and none of them is a restriction:
///
///   `Page`      the door itself. The one thing here that is Passenger's.
///   `console`   **rebuilt so that all of it goes to stderr**, and this one is
///               not negotiable at any level of trust. `console.log` writes to
///               stdout, which is the JSON-RPC transport, so one tracing line
///               in a caller's script corrupts the stream it is travelling on.
///               Passed as an argument precisely so it *shadows* the real
///               global rather than hoping the caller avoids it.
///   `fs`/`path` bound for convenience, because every recipe in the skill uses
///               them -- the walker is read off disk and bytes that cannot
///               cross back as JSON are written out. `require` reaches the same
///               modules; these two save the ceremony.
///   `require`   this file's own, from `createRequire`. ES module scope has no
///               `require` global to inherit, so a script that wants a module
///               would otherwise have nothing but dynamic `import`.
///
/// Every method on `console`, pointed at stderr. Not a subset: a script
/// reaching for `console.table` or `console.dir` must not be the one that
/// breaks the wire.
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
@module("node:module") external createRequire: string => 'a = "createRequire"

let require = createRequire(%raw(`import.meta.url`))

let apply: ('f, 'a, 'b, 'c, 'd, 'e) => promise<'r> = %raw(`(f, a, b, c, d, e) => f(a, b, c, d, e)`)

/// Run the script and return what it returned, checked.
///
/// Raises for the three ways this goes wrong -- source that will not parse, a
/// script that threw, and a value that cannot leave -- each naming which one it
/// was, since the caller's next move differs for each.
let execute = async (source, page) => {
  let body = compile(source)->Node.runInThisContext
  switch await apply(body, page, quietConsole, fs, path, require) {
  | returned => crossable(returned)
  | exception JsExn(e) => throw(raised(e, source))
  }
}
