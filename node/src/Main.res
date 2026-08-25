// The walking skeleton: one tool, over stdio, against the Chrome that is
// already running. Not the port -- the four things that could stop the port,
// proved together.

let cdp = "http://127.0.0.1:9222"

type state = {mutable browser: option<Pw.browser>}
let state = {browser: None}

let browser = async () =>
  switch state.browser {
  | Some(b) => b
  | None =>
    let b = await Pw.connectOverCDP(Pw.chromium, cdp)
    state.browser = Some(b)
    b
  }

// One page per call for now. Lanes are `Lanes.cs`'s job and are not in this
// skeleton: what is being proved here is that a page can be reached at all.
let freshPage = async () => {
  let b = await browser()
  let ctx = (await browser())->Pw.contexts->Array.getUnsafe(0)
  ignore(b)
  await Pw.newPage(ctx)
}

// The line a caller's failure happened on, dug out of the stack trace the way
// the vm's `filename` puts it there. `<script>` matches what the C# door
// reports, so a caller reading either sees the same name.
let lineOf = (stack: string) =>
  switch stack->String.match(%re("/<script>:(\d+)/")) {
  | Some(m) =>
    switch m->Array.get(1) {
    | Some(Some(n)) => Int.fromString(n)
    | _ => None
    }
  | None => None
  }

let runScript = async (source: string) => {
  let page = await freshPage()
  let ctx = Node.createContext({"Page": page, "console": Console.error})
  try {
    let returned = await Node.script(Node.wrap(source), {"filename": "<script>"})->Node.runInContext(ctx)
    let url = Pw.url(page)
    // The skeleton owns nothing: no lanes yet, so it does not get to leave a
    // tab behind in a browser other callers are sharing.
    await Pw.closePage(page)
    Dict.fromArray([
      ("type", JSON.Encode.string("ran")),
      ("url", JSON.Encode.string(url)),
      ("returned", returned),
    ])
  } catch {
  | JsExn(e) =>
    let stack = JsExn.stack(e)->Option.getOr("")
    await Pw.closePage(page)
    Dict.fromArray([
      ("type", JSON.Encode.string("failed")),
      ("error", JSON.Encode.string(JsExn.message(e)->Option.getOr("unknown"))),
      ("line", switch lineOf(stack) {
      | Some(n) => JSON.Encode.int(n)
      | None => JSON.Encode.null
      }),
    ])
  }
}

let tool = {
  "name": "script",
  "description": "Open a page, drive it, and read it -- the only door onto the browser.",
  "inputSchema": {
    "type": "object",
    "properties": {"source": {"type": "string", "description": "JavaScript. `return` what you want back."}},
    "required": ["source"],
  },
}

let server = Mcp.server(
  {"name": "passenger", "version": "0.1.0"},
  {"capabilities": {"tools": Dict.make()}},
)

server->Mcp.setRequestHandler(Mcp.listToolsRequest, async _ => {"tools": [tool]})

server->Mcp.setRequestHandler(Mcp.callToolRequest, async req => {
  let source =
    req["params"]["arguments"]["source"]->Option.getOr("return 'no source given';")
  let out = await runScript(source)
  {
    "content": [{"type": "text", "text": JSON.stringifyAny(out)->Option.getOr("{}")}],
  }
})

let main = async () => {
  await server->Mcp.connect(Mcp.stdio())
}

main()->Promise.ignore
