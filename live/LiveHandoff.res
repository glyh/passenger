// The whole handoff path, opening no window.
//
// Not a test, and the reason it can run at all is the `web` presenter: it hands
// back a URL rather than putting a browser on somebody's desktop. What that
// still exercises is everything behind it -- the screen claim, `Webserve.ensure`
// re-execing this same module as a detached viewer server, the scale probe, and
// `hideBrowser` releasing the claim again.

@val @scope("process") external env: Dict.t<string> = "env"
@val @scope("process") external kill: (int, string) => unit = "kill"

let port = 6096

let childEnv = () => {
  let merged = Dict.make()
  env->Dict.forEachWithKey((value, key) => merged->Dict.set(key, value))
  merged->Dict.set("PASSENGER_PRESENTER", "web")
  merged->Dict.set("PASSENGER_NOVNC_PORT", port->Int.toString)
  merged
}

let main = async () => {
  let client = Mcp.client({"name": "live-handoff", "version": "0"})
  await client->Mcp.connectClient(
    Mcp.stdioClient({
      "command": "node",
      "args": ["src/cli/Main.res.mjs", "serve"],
      "cwd": Node.cwd(),
      "stderr": "inherit",
      "env": childEnv(),
    }),
  )

  let call = async (name, args) =>
    switch await client->Mcp.callTool({"name": name, "arguments": args}) {
    | reply =>
      let text = (reply["content"]->Array.getUnsafe(0))["text"]
      Console.log(`${name} -> ${text}`)
      Some(text)
    | exception JsExn(e) =>
      Console.log(`${name} !! ${JsExn.message(e)->Option.getOr("?")}`)
      None
    }

  let lane = (await call("openLane", Dict.make()))->Option.getOr("")
  let _ = await call("browserStatus", Dict.make())
  let _ = await call("showBrowser", {"lane": lane})
  let _ = await call("browserStatus", Dict.make())
  let _ = await call("hideBrowser", {"lane": lane})
  let _ = await call("destroyLane", {"lane": lane})

  switch Sessions.listenerOn(port) {
  | Some((pid, command)) =>
    Console.log(`viewer server: ${command}`)
    kill(pid, "SIGTERM")
  | None => Console.log("viewer server: none")
  }
  await client->Mcp.closeClient
}

main()->Promise.ignore
