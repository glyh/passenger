// Imperative shell: serving the page a human takes the browser over in.
//
// Two roots and nothing else: the viewer page that ships beside this code, and
// noVNC's own modules, which are read from wherever the packaging put them. A
// general-purpose static server over one merged directory would have been less
// code, but it would also have to be pointed at a directory containing both --
// and building that means copying noVNC out of the store at runtime.
//
// The process is detached and outlives the command that started it, the same way
// sway and wayvnc do, because `showBrowser` returns while the window stays open.

/// The viewer page.
let page = () => Assets.read("web/viewer.html")

/// Lived on `PicturesJs` until ticket 048 deleted it, which left the viewer page
/// as the one asset this module reads.
let novncCandidates = ["/usr/share/webapps/novnc", "/usr/share/novnc", "/usr/local/share/novnc"]

/// Where noVNC's modules live, or `None` if this machine has none.
///
/// PASSENGER_NOVNC first, which is what the flake sets to a store path holding
/// just the static files; the well-known distribution paths after it, so a
/// system-installed noVNC works without configuration.
let novncRoot = () => {
  let holdsNovnc = dir => Fs.existsSync(Fs.join(Fs.join(dir, "core"), "rfb.js"))
  switch Config.novncDir.contents {
  | Some(configured) => holdsNovnc(configured) ? Some(configured) : None
  | None => novncCandidates->Array.find(holdsNovnc)
  }
}

/// Map a request to a file, or to nothing at all.
///
/// Deliberately not a general static server, which would serve the whole working
/// directory: this process exists to hand out two things, and a static server
/// that will read any file it can reach is not something to leave listening on a
/// socket, however local.
///
/// Pure, and separated from the serving so the containment check is testable
/// without binding a port. That check is the security-relevant half: `..` in a
/// request must not walk out of the noVNC tree.
let prefix = "/novnc/"

let translatePath = (path, root) => {
  let clean =
    path
    ->String.split("?")
    ->Array.getUnsafe(0)
    ->String.split("#")
    ->Array.getUnsafe(0)
  if clean == "/" || clean == "/index.html" {
    // The empty string means "the viewer page", which is how it is served
    // without a path to get wrong.
    Some("")
  } else if clean->String.startsWith(prefix) {
    let rest = clean->String.slice(~start=prefix->String.length, ~end=clean->String.length)
    let full = Fs.resolve(Fs.join(root, rest))
    let within = Fs.resolve(root)
    full->String.startsWith(within ++ "/") || full == within ? Some(full) : None
  } else {
    None
  }
}

let contentTypes = Dict.fromArray([
  (".html", "text/html; charset=utf-8"),
  (".js", "text/javascript; charset=utf-8"),
  (".mjs", "text/javascript; charset=utf-8"),
  (".css", "text/css; charset=utf-8"),
  (".json", "application/json"),
  (".svg", "image/svg+xml"),
  (".png", "image/png"),
  (".ico", "image/x-icon"),
  (".woff", "font/woff"),
  (".woff2", "font/woff2"),
])

/// What the viewer page says about itself.
///
/// Identity has to survive a rebuild -- an older build of this tool left serving
/// the port is still ours -- so it is this one stable line rather than the whole
/// page compared byte for byte.
let pageMark = "<title>passenger</title>"

/// Did this body come from us? Pure, so it is testable.
let isViewerPage = body => body->Option.getOr("")->String.includes(pageMark)

// --- the server -------------------------------------------------------------

type httpServer
type request
type response

@module("node:http") external createServer: (('req, 'res) => unit) => httpServer = "createServer"
@send external listen: (httpServer, int, string) => unit = "listen"
@get external requestUrl: request => Nullable.t<string> = "url"
@set external statusCode: (response, int) => unit = "statusCode"
@send external setHeader: (response, string, string) => unit = "setHeader"
@send external endWith: (response, 'body) => unit = "end"
@send external endBare: response => unit = "end"

let serve = (port, root) => {
  let server = createServer((req: request, res: response) => {
    let path = req->requestUrl->Nullable.toOption->Option.getOr("/")
    switch translatePath(path, root) {
    | None =>
      res->statusCode(404)
      res->endBare
    | Some("") =>
      res->setHeader("content-type", contentTypes->Dict.get(".html")->Option.getOr("text/html"))
      res->endWith(page())
    | Some(target) =>
      switch Fs.readFileBytes(target) {
      | body =>
        res->setHeader(
          "content-type",
          contentTypes
          ->Dict.get(Fs.extname(target))
          ->Option.getOr("application/octet-stream"),
        )
        res->endWith(body)
      | exception _ =>
        res->statusCode(404)
        res->endBare
      }
    }
  })
  server->listen(port, Config.vncHost.contents)
}

// --- is it up, and is it ours -----------------------------------------------

/// Is something already serving on that port?
let listening = port => NestedSessions.isListening(Config.vncHost.contents, port)

@val external fetch: (string, {..}) => promise<'res> = "fetch"
@send external text: 'res => promise<string> = "text"
@get external ok: 'res => bool = "ok"
@val external abortSignalTimeout: int => 'signal = "AbortSignal.timeout"

/// The body served at a path, or `None` if nothing usable came back.
///
/// One short timeout: everything it talks to is on loopback and already up, so a
/// request that takes seconds has already told us what we needed to know.
let fetchPath = async (port, ~path="/") =>
  switch await fetch(
    `http://${Config.vncHost.contents}:${port->Int.toString}${path}`,
    {"signal": abortSignalTimeout(2000)},
  ) {
  | res => res->ok ? Some(await res->text) : None
  | exception _ => None
  }

/// Is *our* viewer answering on that port -- not merely something?
///
/// The question `listening` was standing in for, and could not answer. One
/// request against a server that is by definition local and up.
let serving = async port => isViewerPage(await fetchPath(port))

/// Whoever is on the port, and why this tool is not taking it from them.
///
/// Naming the pid and the command line is the whole value here: the human reading
/// this is the one who can decide whether that process is disposable. Killing it
/// would be this tool's decision to make on their behalf, out of an agent-facing
/// call, which is the kind of destructive act ticket 057 deliberately kept out of
/// agent hands.
let squatter = port => {
  let who = switch NestedSessions.listenerOn(port) {
  | Some((pid, command)) => `pid ${pid->Int.toString} (${command})`
  | None => "an unidentifiable process"
  }
  `${who} answers on ${port->Int.toString} but serves no viewer page; stop it and ` ++
  "call again. This tool will not kill a process it did not start"
}

// --- starting it ------------------------------------------------------------

/// The private re-exec argument. Not a public verb: nothing but `ensure` should
/// ask for it, and it takes no other arguments.
let serveFlag = "--serve-viewer"

@val @scope("process") external argv: array<string> = "argv"
@val @scope("process") external execPath: string = "execPath"

/// Re-runs this same script under the same node, which is the shape
/// `python -m passenger.webserve` had and `dotnet Passenger.Cli.dll` needed a
/// special case for. Here there is only one: argv[0] is the runtime and argv[1]
/// is the entry module, always.
let reExecArgs = port => [
  argv->Array.get(1)->Option.getOr(""),
  serveFlag,
  port->Int.toString,
]

/// Start the server unless *our* server is already up. False if it cannot be, and
/// a PORT_IN_USE failure if the port belongs to somebody else.
///
/// Started as a detached child rather than in this process because the server
/// must keep serving the page for as long as the window it opened is open, and
/// this process may be answering an entirely different call by then.
let ensure = async port =>
  if await serving(port) {
    true
  } else if await listening(port) {
    // Something is there and it is not us. Ticket 058: this used to be a socket
    // probe alone, so a predecessor of this tool left holding the port made
    // `ensure` return true without starting anything, and the URL `showBrowser`
    // handed a human was a 404 from a stranger.
    Errors.fail(PortInUse, "the viewer port is taken", ~detail=squatter(port))
  } else if novncRoot()->Option.isNone {
    false
  } else {
    switch Proc.detach(execPath, reExecArgs(port)) {
    | None => false
    | Some(_) =>
      // Serving, not listening: the bind happens before the first route exists,
      // and a caller told "yes" in that window is told a URL it could not have
      // fetched.
      await Poll.until(~times=20, ~everyMs=100, () => serving(port))
    }
  }

@val @scope("process") external exit: int => unit = "exit"

/// The re-exec entry point, called before anything else is parsed. Returns true
/// when it handled the arguments and served.
let serveIfAsked = args =>
  switch args->Array.get(0) {
  | Some(flag) if flag == serveFlag =>
    switch novncRoot() {
    | None =>
      Console.error("no noVNC installation found; set PASSENGER_NOVNC")
      exit(1)
      true
    | Some(root) =>
      let port =
        args->Array.get(1)->Option.flatMap(p => Int.fromString(p))->Option.getOr(
          Config.novncPort.contents,
        )
      serve(port, root)
      true
    }
  | _ => false
  }
