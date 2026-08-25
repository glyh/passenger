// The passthrough door's core. Pure: no browser, no page.
//
// The oracle is `tests/Passenger.Tests/ScriptTests.cs`, and all thirteen of its
// cases are here. Three had to change shape, in the opposite direction from the
// C# port's own change.
//
// That side could not *construct* a Playwright handle -- hand-implementing
// ILocator would be a hundred members that break on every driver update -- so it
// asserted its rule over `Type` objects. This side can construct one trivially,
// but only with a browser attached, and a pure suite must not need one. So the
// rule is pinned here against stand-ins carrying the shape that was measured off
// live handles, and that the live objects still have that shape is pinned in
// `live-session.mjs`, which does have a browser. Neither half is enough alone:
// the unit test would not notice Playwright changing its internals, and the live
// check would not notice the rule losing a case.

// The three shapes, as measured against playwright-core 1.62. See the comment
// over `Script.handleName` for what was found and how.
let channelOwner = {"_type": "Page", "_guid": "page@79c7d4d0"}
let locator = {"_apiName": "Locator", "_frame": {"_type": "Frame", "_guid": "frame@b94fca7c"}}
let apiResponse = {"_apiName": "APIResponse", "_request": {"_guid": "request-context@2046b027"}}
let keyboard = {"_page": {"_type": "Page", "_guid": "page@79c7d4d0"}}

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

T.test("a type nobody listed is still a handle", () => {
  // The bug the list had. `IAPIResponse` was not among the eight types named by
  // hand on the C# side, so `return await Page.APIRequest.GetAsync(url)`
  // serialised the driver's own headers and timings and handed them back as if
  // they were the answer -- no error, and not the body the caller asked for.
  // Found by writing the skill's picture recipe (ticket 049) and running it.
  T.equal(Script.handleName(apiResponse), Some("APIResponse"))
  // And the shape nothing would think to list at all: an object that is not a
  // handle itself but holds one.
  T.equal(Script.handleName(keyboard), Some("Playwright handle"))
})

T.test("a handle is refused by name", () => {
  // Ticket 013: nearly every Playwright call hands back an object that cannot
  // be JSON, so the error has to say what to return instead rather than
  // surfacing a serialisation stack trace.
  T.equal(Script.handleName(channelOwner), Some("Page"))
  T.equal(Script.handleName(locator), Some("Locator"))
})

T.test("what a script is meant to return is not a handle", () => {
  // The other side of the rule: a script's usual return -- text, a list of
  // hrefs, a record of fields -- must not be caught by it.
  T.equal(Script.handleName("text"->Obj.magic), None)
  T.equal(Script.handleName(["a", "b"]->Obj.magic), None)
  T.equal(Script.handleName({"title": "x", "href": "y"}->Obj.magic), None)
  T.equal(Script.handleName(Nullable.null->Obj.magic), None)
  T.equal(Script.handleName(7->Obj.magic), None)
})

T.test("the refusal says what to return instead", () => {
  switch Script.crossable(locator) {
  | _ => T.ok(false)
  | exception Errors.Passenger({code, detail}) =>
    T.equal(code, ScriptReturnNotJson)
    T.ok(detail->Option.getOr("")->String.includes("return what you wanted"))
  }
})

T.test("a value no rule could name is refused too", () => {
  // The second half of the check, which catches what no shape test could: a
  // cycle. `JSON.stringify` genuinely refuses it, where it would happily walk
  // into a live handle -- which is why the shape test has to come first.
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
})

T.test("the reported line is the caller's own text", () => {
  // Reported against the source the caller sent, so the line numbers are the
  // ones they can see.
  T.equal(Script.lineOf("var a = 1;\nvar b = 2;\n", 2), "var b = 2;")
  T.equal(Script.lineOf("var a = 1;", 9), "")
})
