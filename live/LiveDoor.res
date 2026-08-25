// The ten tools, driven over stdio the way a client drives them.
//
// Not a test: it opens a real lane against the shared browser, navigates the
// public web, and provokes each of the three script failures. What it proves
// that a unit test cannot is that the transport, the schemas and the reply shape
// all agree with each other.

let short = text => text->String.length > 300 ? text->String.slice(~start=0, ~end=300) ++ "..." : text

let main = async () => {
  let client = Mcp.client({"name": "live-door", "version": "0"})
  await client->Mcp.connectClient(
    Mcp.stdioClient({
      "command": "node",
      "args": ["src/cli/Main.res.mjs", "serve"],
      "cwd": Node.cwd(),
      "stderr": "inherit",
    }),
  )

  let call = async (name, args) =>
    switch await client->Mcp.callTool({"name": name, "arguments": args}) {
    | reply =>
      let text = (reply["content"]->Array.getUnsafe(0))["text"]
      Console.log(`${name} -> ${short(text)}`)
      Some(text)
    | exception JsExn(e) =>
      Console.log(`${name} !! ${JsExn.message(e)->Option.getOr("?")}`)
      None
    }

  Console.log(
    "tools: " ++ (await client->Mcp.listTools)["tools"]->Array.map(t => t["name"])->Array.join(", "),
  )

  let lane = (await call("openLane", Dict.make()))->Option.getOr("")
  let ran = await call(
    "script",
    {
      "lane": lane,
      "source": `await Page.goto('https://www.chinanews.com.cn/');
return { title: await Page.title(), emoji: '😀 腾冲',
         n: await Page.evaluate(() => document.querySelectorAll('a').length) };`,
    },
  )
  let tab =
    ran
    ->Option.flatMap(t => t->JSON.parseOrThrow->JSON.Decode.object)
    ->Option.flatMap(o => o->Dict.get("tab"))
    ->Option.flatMap(v => v->JSON.Decode.string)
    ->Option.getOr("")

  // The same tab again, which is what continuing a sequence looks like.
  let _ = await call("script", {"lane": lane, "tab": tab, "source": "return Page.url();", "checkWall": false})

  // The three failures, each naming which one it was.
  let _ = await call("script", {"lane": lane, "tab": tab, "source": "const a = 1;\nthrow new Error('deliberate, line 2');"})
  let _ = await call("script", {"lane": lane, "tab": tab, "source": "var x = 1;\nvar y = (;"})
  let _ = await call("script", {"lane": lane, "tab": tab, "source": "return Page.locator('body');"})

  let _ = await call("listTabs", {"lane": lane})
  let _ = await call("script", {"lane": lane, "source": "return 'a second tab';", "checkWall": false})
  let _ = await call("listTabs", {"lane": lane})

  // A lane may not touch another lane's tab, and cannot tell that from absent.
  let other = (await call("openLane", Dict.make()))->Option.getOr("")
  let _ = await call("script", {"lane": other, "tab": tab, "source": "return 1;"})
  let _ = await call("destroyLane", {"lane": other})

  let _ = await call("setTtl", {"lane": lane, "minutes": 5})
  let _ = await call("closeAllTabs", {"lane": lane})
  let _ = await call("destroyLane", {"lane": lane})
  let _ = await call("script", {"lane": lane, "source": "return 1;"})
  let _ = await call("browserStatus", Dict.make())

  await client->Mcp.closeClient
}

main()->Promise.ignore
