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

T.testAsync("a name nobody bound is not in scope", async () => {
  // `read` was bound beside `Page` until ticket 046 retired extraction, and
  // `fetch` is left out on purpose -- it would be a way onto the web that goes
  // around the browser. Both fail the same way, at the caller's own line.
  switch await Script.execute("return fetch('https://example.com');", Nullable.null) {
  | _ => T.ok(false)
  | exception Errors.Passenger({code, message}) =>
    T.equal(code, ScriptRaised)
    T.ok(message->String.includes("fetch"))
  }
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
