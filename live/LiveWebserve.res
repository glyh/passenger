// The viewer server's routes, in this process, on a scratch port.
//
// Not a test: it needs a real noVNC installation, which the suite must not.

@val external fetch: string => promise<'res> = "fetch"
@get external status: 'res => int = "status"
@get external headers: 'res => 'h = "headers"
@send external getHeader: ('h, string) => Nullable.t<string> = "get"
@val @scope("process") external exit: int => unit = "exit"

let port = 6099

let main = async () =>
  switch Webserve.novncRoot() {
  | None => Console.log("no novnc here; run under nix develop")
  | Some(root) =>
    Config.novncPort := port
    Webserve.serve(port, root)
    await Timers.sleep(200)
    let base = `http://127.0.0.1:${port->Int.toString}`

    Console.log(`serving() says ours: ${(await Webserve.serving(port)) ? "true" : "false"}`)
    let rfb = await fetch(`${base}/novnc/core/rfb.js`)
    Console.log(
      `novnc module: ${rfb->status->Int.toString} ` ++
      (rfb->headers->getHeader("content-type"))->Nullable.toOption->Option.getOr("?"),
    )
    Console.log(
      `walking out: ${(await fetch(`${base}/novnc/../../../etc/passwd`))->status->Int.toString}`,
    )
    Console.log(`anything else: ${(await fetch(`${base}/etc/passwd`))->status->Int.toString}`)
    exit(0)
  }

main()->Promise.ignore
