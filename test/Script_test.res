// The passthrough door's core. Pure: no browser, no page.
//
// The oracle was `tests/Passenger.Tests/ScriptTests.cs`. Nine of its thirteen
// cases are here; the other four pinned a rule that no longer exists.
//
// That rule refused a live Playwright handle by name, and it was a C#
// inheritance rather than a fact about this runtime -- see the comment over
// `Script.crossable` for what was measured and why it went. What is left of the
// boundary is the one case that is genuinely not JSON, and it is below.

T.testAsync("a script returns a value", async () => {
  // `return` at the top level of the source, which a module cannot do. The
  // async IIFE gives it, and gives top-level `await` with it -- the Python side
  // wrapped the source in a function for the same reason and paid a line of
  // offset in every traceback for it, which the missing newline avoids here.
  T.equal(await Script.execute("return 1 + 1;", Nullable.null), 2->Obj.magic)
})

T.testAsync("the script can see the page", async () => {
  // `Page` is the one bound name. Handed null, so a script that reads a member
  // off it throws -- which is the proof the name resolved. A missing name would
  // have thrown a ReferenceError at run time, not this.
  switch await Script.execute("return Page.url();", Nullable.null) {
  | _ => T.ok(false)
  | exception Errors.Passenger({code, message}) =>
    T.equal(code, ScriptRaised)
    T.ok(message->String.includes("TypeError"))
  }
})

T.testAsync("this process's own globals are in scope", async () => {
  // The reversal ticket 074 made. `fetch` is the pointed case: it was left out
  // by name from ticket 046 and this test asserted the `ReferenceError` that
  // came of it -- which was measuring the wall rather than anything true. The
  // *design* is unchanged, and `Page.request` is still the sanctioned way onto
  // the web; what went is the pretence that a missing name enforced it on a
  // process running on the caller's own machine.
  //
  // Typeof rather than a call, deliberately: this suite does not touch the
  // network, and the old version of this test spent 258ms reaching example.com
  // to prove a negative.
  T.equal(
    await Script.execute("return [typeof fetch, typeof process, typeof URL].join();", Nullable.null),
    "function,object,function"->Obj.magic,
  )
})

T.testAsync("a name genuinely nobody bound is still a ReferenceError", async () => {
  // The other half: scope is this process's, not everything imaginable. Still
  // reported at the caller's own line.
  switch await Script.execute("return notAName;", Nullable.null) {
  | _ => T.ok(false)
  | exception Errors.Passenger({code, message}) =>
    T.equal(code, ScriptRaised)
    T.ok(message->String.includes("notAName"))
  }
})

T.testAsync("require reaches a module", async () => {
  // ES module scope has no `require` to inherit, so a script that wants one
  // has to be handed it -- `fs` and `path` are the same modules, kept by name
  // because every recipe in the skill uses them.
  T.equal(
    await Script.execute("return typeof require('node:os').platform();", Nullable.null),
    "string"->Obj.magic,
  )
})

T.testAsync("a bound name can be redeclared, and shadows", async () => {
  // A regression, and it was introduced by ticket 074 rather than found in it.
  // The five bound names are *parameters* of the wrapper now, so `const path =
  // "/tmp/x.md"` -- an entirely ordinary line, and one this repo's own skill
  // recipe used -- was redeclaring a parameter: `SyntaxError: Identifier 'path'
  // has already been declared`, before the browser was touched. In the `vm`
  // context they had been context globals, where the same line shadowed
  // happily. `Node.wrap` puts the caller's source in a nested block to give
  // that back.
  T.equal(await Script.execute(`const path = "/tmp/x.md"; return path;`, Nullable.null),
    "/tmp/x.md"->Obj.magic)
  // ...and the name still works for everyone who did not take it.
  T.equal(await Script.execute(`return path.join("a", "b");`, Nullable.null), "a/b"->Obj.magic)
})

T.testAsync("this module's own bindings are not in a script's scope", async () => {
  // The bound names arrive as arguments, not by lexical capture:
  // `runInThisContext` compiles against the realm's globals, so nothing in
  // Script.res is visible to a caller's source. `path` resolving while
  // `scriptPath` does not is the whole distinction.
  T.equal(
    await Script.execute("return [typeof path, typeof scriptPath, typeof crossable].join();", Nullable.null),
    "object,undefined,undefined"->Obj.magic,
  )
})

T.testAsync("a bound name can be redeclared, and shadows", async () => {
  // A regression introduced by ticket 074 rather than found in it. The bound
  // names are *parameters* of the wrapper now, so `const path = "/tmp/x.md"`
  // -- an entirely ordinary line, and one this repo's own skill recipe used --
  // was redeclaring a parameter: `SyntaxError: Identifier 'path' has already
  // been declared`, before the browser was touched. In the `vm` context they
  // had been context globals and the same line shadowed happily.
  //
  // Fixed by putting the caller's source in a block, not by unbinding the
  // name. Unbinding was tried and is the wrong direction: it fixes a caller
  // who wanted the variable by taking the module away from one who wanted the
  // module. Both work now.
  T.equal(
    await Script.execute(`const path = "/tmp/x.md"; return path;`, Nullable.null),
    "/tmp/x.md"->Obj.magic,
  )
  T.equal(await Script.execute(`return path.join("a", "b");`, Nullable.null), "a/b"->Obj.magic)
})

T.testAsync("this module's own bindings are not in a script's scope", async () => {
  // The bound names arrive as arguments, not by lexical capture:
  // `runInThisContext` compiles against the realm's globals, so nothing in
  // Script.res is visible to a caller's source. `path` resolving while
  // `scriptPath` does not is the whole distinction.
  //
  // Worth a test rather than a comment because the obvious way to check it by
  // hand is wrong: `node -e` exposes node's builtin modules as globals, so a
  // bare `path` answers there whether or not anything bound it.
  T.equal(
    await Script.execute(
      "return [typeof path, typeof scriptPath, typeof crossable].join();",
      Nullable.null,
    ),
    "object,undefined,undefined"->Obj.magic,
  )
})

T.testAsync("a script's own const shadows a bound name", async () => {
  // The recipes in the skill write `const path = "/tmp/pep8.md"` -- naming the
  // file they are about to write -- so the five names in `context` must not
  // collide with a caller's own variables. A vm context puts top-level `const`
  // in that context's lexical scope, which is consulted before the global
  // object, so this is shadowing rather than a collision.
  T.equal(
    await Script.execute(`const path = "/tmp/x.md"; return path;`, Nullable.null),
    "/tmp/x.md"->Obj.magic,
  )
  // ...and the name is still the module for a caller who did not take it.
  T.equal(await Script.execute(`return path.join("a", "b");`, Nullable.null), "a/b"->Obj.magic)
})

T.testAsync("require is the only module loader", async () => {
  // `import()` needs a loader the vm context has no callback for, so a recipe
  // reaching for it gets `A dynamic import callback was not specified`. The
  // skill says `require` for that reason, and this pins it.
  T.equal(
    await Script.execute(`return require("node:path").join("a", "b");`, Nullable.null),
    "a/b"->Obj.magic,
  )
  switch await Script.execute(`return await import("node:os");`, Nullable.null) {
  | _ => T.ok(false)
  | exception Errors.Passenger({code}) => T.equal(code, ScriptRaised)
  }
})

T.testAsync("console is shadowed, not inherited", async () => {
  // The one thing that is not a matter of trust: stdout is the JSON-RPC
  // transport, so a caller's `console.log` must not reach it. It is passed as
  // an *argument* named `console` precisely so it shadows the real global --
  // this asserts the identity, since asserting the absence of stdout bytes
  // from inside the process running the test is not something a test can see.
  T.equal(
    await Script.execute("return console.log === globalThis.console.log;", Nullable.null),
    false->Obj.magic,
  )
})

T.test("a value that is not JSON is refused", () => {
  // What the boundary is actually for. A cycle is not a JSON document and no
  // amount of good intent makes it one, so this is a refusal rather than a
  // guess about what the caller meant.
  let cycle = Dict.make()
  cycle->Dict.set("self", cycle->Obj.magic)
  switch Script.crossable(cycle) {
  | _ => T.ok(false)
  | exception Errors.Passenger({code}) => T.equal(code, ScriptReturnNotJson)
  }
})

T.testAsync("a syntax error points at the caller's own line", async () => {
  switch await Script.execute("var x = 1;\nvar y = (;", Nullable.null) {
  | _ => T.ok(false)
  | exception Errors.Passenger({code, message}) =>
    T.equal(code, ScriptInvalid)
    T.ok(message->String.includes("line 2"))
  }
})

T.testAsync("a throw reports the line it came from", async () => {
  // What ticket 023's measurement 3 found C# gives no line number for without
  // WithEmitDebugInformation, WithFilePath and the Stream overload of Create.
  // Here it costs a `filename` and a wrapper that adds no newline, and this
  // asserts both stay that way.
  switch await Script.execute("var a = 1;\nvar b = 2;\nthrow new Error('nope');", Nullable.null) {
  | _ => T.ok(false)
  | exception Errors.Passenger({code, message, detail}) =>
    T.equal(code, ScriptRaised)
    T.equal(message, "Error: nope")
    T.ok(detail->Option.getOr("")->String.includes("line 3"))
    // And the wrapper's own closing line, one past the end of the source, is
    // not reported as a frame the caller wrote.
    T.ok(!(detail->Option.getOr("")->String.includes("line 4")))
  }
})

T.testAsync("an empty script is not an error", async () => {
  // Nothing to return is a script that ran, not a script that broke.
  T.equal(await Script.execute("", Nullable.null), Nullable.undefined->Obj.magic)
})

T.test("ordinary values cross", () => {
  T.equal(Script.crossable("text"), "text")
  T.equal(Script.crossable(["a", "b"]), ["a", "b"])
  T.equal(Script.crossable(Nullable.null), Nullable.null)
  // And so does a caller's own data that happens to look like Playwright's.
  // The rule this replaced would have refused it: a site whose JSON carries a
  // field called `_guid` is a site, not a handle.
  T.equal(Script.crossable({"_guid": "row-7", "title": "x"}), {"_guid": "row-7", "title": "x"})
})

T.test("the reported line is the caller's own text", () => {
  // Reported against the source the caller sent, so the line numbers are the
  // ones they can see.
  T.equal(Script.lineOf("var a = 1;\nvar b = 2;\n", 2), "var b = 2;")
  T.equal(Script.lineOf("var a = 1;", 9), "")
})

// Annotated concretely: a `%raw` cannot carry a type variable, and the only
// caller hands it a unit-returning thunk anyway.
let captureStdout: (unit => promise<unit>) => promise<string> = %raw(`async (body) => {
  const original = process.stdout.write.bind(process.stdout);
  let captured = "";
  process.stdout.write = (chunk) => { captured += chunk; return true; };
  try { await body(); } finally { process.stdout.write = original; }
  return captured;
}`)

T.testAsync("a script's console cannot reach stdout", async () => {
  // stdout is the JSON-RPC transport. Handing a caller the real `console`
  // looked right and was not -- `console.log` writes there, so one tracing line
  // in a script corrupted the stream it was travelling on. Found by writing the
  // skill, after the comment in `Script.res` had claimed stderr for a while.
  //
  // Asserted over every method rather than `log` alone: a script reaching for
  // `console.table` must not be the one that breaks the wire.
  let leaked = await captureStdout(async () => {
    let _ = await Script.execute(
      "console.log('a'); console.info('b'); console.warn('c'); console.table([{x:1}]); return 1;",
      Nullable.null,
    )
  })
  T.equal(leaked, "")
})

T.testAsync("a throw with no message shows what was thrown", async () => {
  // `throw` takes any value, and four common ways of using it carry neither
  // `name` nor `message`. Reading those two and defaulting both produced
  // "Error:" and nothing else, which told a caller nothing about their own
  // script. Found by throwing all four at the door.
  let cases = [
    ("throw 42;", "threw 42"),
    ("throw null;", "threw null"),
    ("throw {why: 'no stack'};", `threw {"why":"no stack"}`),
    ("await Promise.reject('bare string');", `threw "bare string"`),
  ]
  for i in 0 to cases->Array.length - 1 {
    let (source, expected) = cases->Array.getUnsafe(i)
    switch await Script.execute(source, Nullable.null) {
    | _ => T.ok(false)
    | exception Errors.Passenger({code, message}) =>
      T.equal(code, ScriptRaised)
      T.equal(message, expected)
    }
  }
})
