// Parsing Chrome's target list. Pure: a recorded payload, no browser.
//
// The oracle is `tests/Passenger.Tests/TargetsTests.cs`, all 13 cases. The C#
// suite reimplemented the counting half of `StuckSummary` inside the test file
// because the real one needed a browser to find wedges in; here that half is
// `Targets.summaryOf`, taking the wedges rather than a browser, so the test
// calls the shipped function instead of a copy of it.

open Models

// Recorded from the live endpoint while a tab sat stuck mid-navigation (ticket
// 012). Note the stuck tab: its title is still the document it had before the
// navigation started, which is why the title cannot be used to tell a stuck tab
// from a healthy one -- only asking its renderer can.
let listing = `[
  {"description": "", "devtoolsFrontendUrl": "/devtools/inspector.html?ws=x",
   "id": "35220A8B", "title": "about:blank", "type": "page",
   "url": "http://10.255.255.1:81/hang",
   "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/35220A8B"},
  {"description": "", "id": "C3E56F6E", "title": "Example Domain",
   "type": "page", "url": "https://example.com/",
   "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/C3E56F6E"},
  {"description": "", "id": "867A5141", "title": "Omnibox Popup",
   "type": "browser_ui", "url": "chrome://omnibox-popup.top-chrome/",
   "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/867A5141"}
]`

T.test("every target is parsed with its socket", () => {
  let targets = Targets.parse(listing)
  T.equal(targets->Array.length, 3)
  T.ok(targets->Array.getUnsafe(0)->(t => t.websocketUrl->String.endsWith("/35220A8B")))
})

T.test("Chrome's own UI is not a page", () => {
  // Chrome lists its omnibox popup as a target. Stopping *its* navigation would
  // be meaningless, and it is not a tab anyone opened.
  T.equal(
    Targets.parse(listing)->Array.filter(isPage)->Array.map(t => t.id),
    ["35220A8B", "C3E56F6E"],
  )
})

T.test("a stuck tab looks ordinary from the outside", () => {
  // Ticket 012: the stuck tab still reports the title of the document it had
  // before the navigation began, and a healthy tab with no <title> reports its
  // URL. Nothing in this payload separates them, which is why unstick asks the
  // renderer instead of reading fields.
  let targets = Targets.parse(listing)
  T.ok(targets->Array.getUnsafe(0)->(t => t.title) != "")
  T.ok(targets->Array.getUnsafe(1)->(t => t.title) != "")
})

// --- What one `Page.getFrameTree` answer says about a tab (ticket 042).
//
// Recorded from the live endpoint against a socket that accepts and then
// answers nothing. Two tabs pointed at it, and they answer *differently*: the
// one that already had a document goes silent, the one created at the URL
// answers at once and says it has no document.

let frame = url =>
  Some(
    JSON.parseOrThrow(
      `{"id": 1, "result": {"frameTree": {"frame": {"id": "9D5703E5", "loaderId": "A1", "url": "${url}"}}}}`,
    ),
  )

let refused = Some(JSON.parseOrThrow(`{"id": 1, "error": {"code": -32000, "message": "Not attached"}}`))

T.test("a renderer that never answers is the wedge 012 knew", () => {
  T.equal(Targets.verdict(None), Some(Silent))
})

T.test("a tab with no document is wedged even though it answered", () => {
  // Ticket 042: the tab reads as healthy by every other measure -- it answers in
  // under 10ms -- and it hangs the attach as hard as a silent one. The empty
  // frame URL is the whole difference.
  T.equal(Targets.verdict(frame("")), Some(Uncommitted))
})

T.test("about:blank is a document and not a wedge", () => {
  // `about:blank` is a page that committed, and a tab sitting on one is the most
  // ordinary thing here.
  T.equal(Targets.verdict(frame("about:blank")), None)
})

T.test("a loaded page is left alone", () => {
  T.equal(Targets.verdict(frame("https://example.com/")), None)
})

T.test("an error reply is not read as a wedge", () => {
  // It is still an answer, so the renderer is alive; it is just not one a frame
  // can be read out of. The remedies stop navigations, so a reply nobody planned
  // for is a bad reason to fire one.
  T.equal(Targets.verdict(refused), None)
})

// --- The summary line `status` prints (ticket 042).

T.test("nothing wedged reads as none", () => {
  // Not "0", and not an empty line: a human reading `status` because the tool
  // stopped answering needs the absence stated.
  T.equal(Targets.summaryOf([]), "none")
})

T.test("each wedge is counted under its own name", () => {
  T.equal(Targets.summaryOf([Silent, Uncommitted, Silent]), "2 silent, 1 uncommitted")
})

T.test("the order does not follow whichever tab answered first", () => {
  // Declaration order, so the same browser reads the same way twice.
  T.equal(Targets.summaryOf([Uncommitted, Silent]), Targets.summaryOf([Silent, Uncommitted]))
})

// --- The opener map, which is how a popup finds its lane (ticket 040).

T.test("a popup's opener is read out of the target list", () => {
  let reply = Some(
    JSON.parseOrThrow(`{"id": 1, "result": {"targetInfos": [
      {"targetId": "PARENT", "type": "page", "openerId": ""},
      {"targetId": "POPUP", "type": "page", "openerId": "PARENT"},
      {"targetId": "WORKER", "type": "service_worker", "openerId": "PARENT"}
    ]}}`),
  )
  // Only the popup: a parent with no opener has nothing to record, and a service
  // worker is not a tab any lane can own.
  T.equal(Targets.openersOf(reply)->Dict.toArray, [("POPUP", "PARENT")])
})

T.test("an answerless opener query is an empty map rather than a failure", () => {
  // Adoption is an improvement over leaving a tab unowned, never a precondition
  // for the caller's actual work.
  T.equal(Targets.openersOf(None)->Dict.toArray, [])
})
