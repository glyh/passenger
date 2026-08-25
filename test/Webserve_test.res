// What the viewer's server will and will not hand out. Pure: no socket bound.
//
// The oracle was `tests/Passenger.Tests/WebserveTests.cs`, all eight cases. The
// rule under test is the security-relevant half of that module. This process
// exists to serve two things, and a static server that will read any file it can
// reach is not something to leave listening on a socket, however local -- so `..`
// in a request must not walk out of the noVNC tree.

let root = "/usr/share/webapps/novnc"

T.test("the root is the viewer page", () => {
  // The empty string means "the page that ships beside the code", which is how
  // it is served without a path to get wrong.
  T.equal(Webserve.translatePath("/", root), Some(""))
  T.equal(Webserve.translatePath("/index.html", root), Some(""))
})

T.test("a query string does not change which file is meant", () =>
  // The viewer is always fetched as `/?ws=host:port`, so this is the ordinary
  // case rather than an edge one.
  T.equal(Webserve.translatePath("/?ws=127.0.0.1:5900", root), Some(""))
)

T.test("novnc modules are served from their own tree", () =>
  T.equal(Webserve.translatePath("/novnc/core/rfb.js", root), Some(`${root}/core/rfb.js`))
)

T.test("a request cannot walk out of the novnc tree", () => {
  T.equal(Webserve.translatePath("/novnc/../../../etc/passwd", root), None)
  T.equal(Webserve.translatePath("/novnc/../../etc/shadow", root), None)
})

T.test("nothing else is served at all", () => {
  // Deliberately not the behaviour of a general static server, which would serve
  // the whole working directory.
  T.equal(Webserve.translatePath("/etc/passwd", root), None)
  T.equal(Webserve.translatePath("/../secrets", root), None)
  T.equal(Webserve.translatePath("/anything.js", root), None)
})

T.test("the viewer page ships with the code", () =>
  // Read from `assets/` beside the compiled modules rather than from the
  // process's working directory, which belongs to whoever launched this.
  T.ok(Webserve.page()->String.includes("<"))
)

T.test("the page this build serves is recognised as ours", () =>
  // The mark is an identity claim, so it has to hold against the page this build
  // actually hands out -- otherwise the check ticket 058 added would call our own
  // server a squatter.
  T.ok(Webserve.isViewerPage(Some(Webserve.page())))
)

T.test("something else on the port is not ours", () => {
  // The shape that started ticket 058: `python -m http.server` holding the viewer
  // port, answering everything except the page itself.
  T.ok(!Webserve.isViewerPage(Some("<html><title>Error response</title>Error code: 404</html>")))
  T.ok(!Webserve.isViewerPage(Some("<title>Directory listing for /</title>")))
  // Nothing came back at all: no listener, or a status that was not 200.
  T.ok(!Webserve.isViewerPage(None))
})
