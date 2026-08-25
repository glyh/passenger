// MCP frontend: the tools, and the whole surface there is.
//
// Two things shape the tool design, and both survive from the C# door:
//
// 1. Handoff does not block by default. A tool call that hangs for five minutes
//    while someone finds a captcha is a bad citizen, so a blocked page returns
//    immediately and the agent decides what to do -- typically ask the user,
//    then call again once they have solved it.
// 2. The daemon starts on demand. A human runs it first; an agent should not
//    have to know that.
//
// The descriptions here carry the *call contract* and nothing else. Operating
// knowledge -- what `blocked` misses, how to recognise a wall, that a read is
// one screen, how to read a page at all -- lives in the `using-passenger`
// skill, shipped from this repo under `skills/`. It used to live here too, and
// six skills in the owner's notes had hand-copied it by the time anyone
// noticed; ticket 032 found that a docstring and those instructions arrive on
// the same event, so a second copy here buys nothing and drifts.
//
// **What the port costs at this door.** The C# side generated the schema from
// the method signature -- bounds and prose included -- so there was no
// hand-written JSON and no second description to drift. That is gone: the SDK's
// low-level `Server` takes a JSON schema, and the only thing that would
// generate one is zod, which is a dependency bought to restate what is written
// here anyway. So the schemas below are written by hand, and the bounds in them
// are the ones the prose says.

// --- reading a call's arguments ---------------------------------------------

// Hand-written schemas mean the SDK validates nothing, so these do. A client
// that omits a required argument gets the same shaped failure as one that sends
// the wrong type, rather than `undefined` reaching Playwright.
let args = (req): Dict.t<JSON.t> =>
  switch req["params"]["arguments"]->Nullable.toOption {
  | Some(dict) => dict
  | None => Dict.make()
  }

let missing = (name, what) =>
  Errors.fail(ScriptInvalid, `${name} is required, and must be ${what}`)

let string = (args, name) =>
  switch args->Dict.get(name)->Option.flatMap(v => v->JSON.Decode.string) {
  | Some(value) => value
  | None => missing(name, "a string")
  }

let optionalString = (args, name) =>
  args->Dict.get(name)->Option.flatMap(v => v->JSON.Decode.string)

let int = (args, name, ~fallback) =>
  args
  ->Dict.get(name)
  ->Option.flatMap(v => v->JSON.Decode.float)
  ->Option.map(f => f->Float.toInt)
  ->Option.getOr(fallback)

let requiredInt = (args, name) =>
  switch args->Dict.get(name)->Option.flatMap(v => v->JSON.Decode.float) {
  | Some(f) => f->Float.toInt
  | None => missing(name, "a number")
  }

let bool = (args, name, ~fallback) =>
  args->Dict.get(name)->Option.flatMap(v => v->JSON.Decode.bool)->Option.getOr(fallback)

let strings = (args, name) =>
  switch args->Dict.get(name)->Option.flatMap(v => v->JSON.Decode.array) {
  | Some(items) => items->Array.filterMap(v => v->JSON.Decode.string)
  | None => missing(name, "an array of strings")
  }

// --- the two things every tool does first -----------------------------------

/// The daemon starts on demand. A human runs it first; an agent should not have
/// to know that.
let ensureDaemon = async () =>
  if !(await Browser.isUp()) {
    (await Browser.start())->ignore
  }

/// Collect expired lanes, then check the caller's is still one of them.
///
/// Order matters: a lane that expired between calls is still a row until the
/// sweep reaches it, so checking first would let a doomed lane through and fail
/// later on a dangling foreign key rather than saying LANE_NOT_FOUND.
///
/// A lane holding the screen when its clock runs out takes its claim with it,
/// and nothing else would then put the viewer away -- so the sweep that frees the
/// last claim is also what dismisses it.
let housekeep = async (~lane=?) => {
  let holders = Lanes.screenClaims()
  let collected = await Lanes.sweep()
  if holders->Array.some(h => collected->Array.includes(h)) && Lanes.screenClaims()->Array.length == 0 {
    Present.select().dismiss()
  }

  switch lane {
  | Some(lane) => Lanes.require(lane)->ignore
  | None => ()
  }
}

// --- the tools --------------------------------------------------------------

let text = value => {"content": [{"type": "text", "text": value}]}

let json = value =>
  text(JSON.stringify(value, ~space=0))

let scriptTool = {
  "name": "script",
  "description": `Open a page, drive it, and read it -- the only door onto the browser.

Navigation, interaction and reading are all this call: \`await Page.goto(url)\`
then whatever you need. The reply carries what you returned, and a \`blocked\`
record if a known vendor's wall is on the tab you ended on. Nothing else: no
character count, no measurement of the page. What you did not return, you did
not ask for.

This tool does not interpret pages, and does not measure them either.
Extraction is yours to write and so is measurement; the \`using-passenger\`
skill carries both recipes.

The tab stays open and comes back in \`tab\`, so a sequence continues across
calls.`,
  "inputSchema": {
    "type": "object",
    "properties": {
      "source": {
        "type": "string",
        "description": `JavaScript, run with \`Page\` (a Playwright Page) in scope. Use \`return\` to
hand a value back; it must be JSON, so return text or a list, never a locator.
Every Playwright call is awaited, and top-level \`await\` works. To just read a
page: await Page.goto(url); return await Page.innerText("body");
For markdown with links and headings, run scripts/markdown.js from the
\`using-passenger\` skill.`,
      },
      "lane": {
        "type": "string",
        "description": "Your lane, from openLane. Tabs opened here are yours: no other caller sees them, and none can close them.",
      },
      "tab": {
        "type": "string",
        "description": "Which tab to run against, from a previous reply or from listTabs. Omit for a fresh blank tab.",
      },
      "timeoutSeconds": {
        "type": "integer",
        "minimum": 1,
        "maximum": 600,
        "description": "Per-call budget for each Playwright operation.",
      },
      "checkWall": {
        "type": "boolean",
        "description": `Test the ending page against the fixed table of vendors' walls (Cloudflare,
reCAPTCHA, hCaptcha, DataDome, Arkose, PerimeterX, a login wall). On by
default, because a wall makes what you returned *wrong* rather than short -- a
challenge page's content in the shape of an answer. Turn it off when you are
driving one page across many calls and know there is no wall: it costs two
round trips. The reply then says \`wallChecked: false\`, so it never implies a
check that did not happen.`,
      },
    },
    "required": ["source", "lane"],
  },
}

// Annotated because an empty dict and an empty array are polymorphic, and a
// module-level value that cannot be generalised will not compile.
let noProperties: Dict.t<JSON.t> = Dict.make()
let nothingRequired: array<string> = []

let openLaneTool = {
  "name": "openLane",
  "description": `Open a lane and return its id. Call this before anything else.

A lane owns the tabs opened in it. Nothing outside it can see or close them,
and nothing it does reaches another caller's tabs. It collects itself after 30
minutes of no calls, closing its tabs -- \`setTtl\` when you know you will be
waiting longer than that.`,
  "inputSchema": {"type": "object", "properties": noProperties, "required": nothingRequired},
}

let setTtlTool = {
  "name": "setTtl",
  "description": `Change how long this lane may sit idle before it is collected.

Every call naming the lane restarts its clock, so this is for waits you are
about to start rather than for work in progress -- asking a human for something
slow, most often.`,
  "inputSchema": {
    "type": "object",
    "properties": {
      "lane": {"type": "string", "description": "The lane, from openLane."},
      "minutes": {
        "type": "integer",
        "minimum": 1,
        "maximum": 1440,
        "description": "Quiet time before this lane and its tabs are collected.",
      },
    },
    "required": ["lane", "minutes"],
  },
}

let listTabsTool = {
  "name": "listTabs",
  "description": "List the tabs in a lane, so a script can be pointed at one of them.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "lane": {
        "type": "string",
        "description": "Whose tabs to list. Your own lane, or 'orphan' for tabs no lane claims -- what a page opened by itself, or a human opened during a handoff.",
      },
    },
    "required": ["lane"],
  },
}

let closeTabsTool = {
  "name": "closeTabs",
  "description": "Close the tabs you name, keeping the session and every other tab alive.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "lane": {"type": "string", "description": "The lane the tabs are in."},
      "tabs": {
        "type": "array",
        "items": {"type": "string"},
        "description": "Which tabs to close, from listTabs or a previous reply. Naming them is required: closing is not something to ask for by omission.",
      },
    },
    "required": ["lane", "tabs"],
  },
}

let closeAllTabsTool = {
  "name": "closeAllTabs",
  "description": "Close every tab in this lane. The lane stays open and reusable.",
  "inputSchema": {
    "type": "object",
    "properties": {"lane": {"type": "string", "description": "The lane to empty."}},
    "required": ["lane"],
  },
}

let destroyLaneTool = {
  "name": "destroyLane",
  "description": `Close this lane's tabs and end the lane. The id stops working.

Say this when you are done, rather than leaving tabs parked until the TTL
reaches them.`,
  "inputSchema": {
    "type": "object",
    "properties": {"lane": {"type": "string", "description": "The lane to end."}},
    "required": ["lane"],
  },
}

let showBrowserTool = {
  "name": "showBrowser",
  "description": `Put the browser on screen so the user can log in or solve a challenge.

Also how you ask for a human deliberately, not only in answer to a \`blocked\`
reply.

By default nothing here inspects the page -- the wait ends when the human closes
the viewer, and the reply says so. \`until="unblocked"\` is the other reading: it
polls the named tab until the wall stops matching. That was
\`fetch(wait_seconds=...)\` before ticket 046 retired it, and it is a measurement
rather than a guess only because the signature table is fixed. Whichever you wait
on, read the tab afterwards and judge for yourself.`,
  "inputSchema": {
    "type": "object",
    "properties": {
      "lane": {
        "type": "string",
        "description": "Your lane. It holds a claim on the screen until you call hideBrowser, so another caller finishing its work cannot take the window away from the person you just asked for help.",
      },
      "tab": {
        "type": "string",
        "description": "Bring this tab to the front first, from a previous reply or from listTabs, so the human lands on the page you mean.",
      },
      "waitSeconds": {
        "type": "integer",
        "minimum": 0,
        "maximum": 900,
        "description": "Block for up to this long. 0 (default) returns as soon as it is on screen.",
      },
      "until": {
        "type": "string",
        "enum": ["closed", "unblocked"],
        "description": "What ends the wait. `closed` (default) waits for the human to close the viewer, which is a fact about the human. `unblocked` waits for the vendor's wall to stop matching on `tab`, which is a fact about the page -- stronger, but it needs a tab and only sees walls this tool can name.",
      },
      "notifyHuman": {
        "type": "boolean",
        "description": "Send a desktop notification or webhook. Set this when the human is not watching this conversation -- running unattended, or on a machine they are not sitting at.",
      },
      "ttlMinutes": {
        "type": "integer",
        "minimum": 1,
        "maximum": 1440,
        "description": "Raise the lane's idle timeout for this handoff. A human who wanders off for longer than the lane's TTL comes back to a tab that was collected.",
      },
    },
    "required": ["lane"],
  },
}

let hideBrowserTool = {
  "name": "hideBrowser",
  "description": `Release your claim on the screen, tucking the browser away if you were the last
one holding it.

This closes nothing: your tabs stay open and your lane stays yours.
\`closeTabs\` closes pages, \`destroyLane\` ends the lane.`,
  "inputSchema": {
    "type": "object",
    "properties": {
      "lane": {
        "type": "string",
        "description": "The lane releasing the screen. The viewer stays up while any other lane still holds a claim.",
      },
    },
    "required": ["lane"],
  },
}

let browserStatusTool = {
  "name": "browserStatus",
  "description": "Report whether the browser is running, and what is on screen.",
  "inputSchema": {"type": "object", "properties": noProperties, "required": nothingRequired},
}

/// A tool declaration, as the SDK wants it.
///
/// One coercion, named once, rather than ten `Obj.magic` in a row. The schemas
/// above are heterogeneous object literals -- that is what a JSON Schema is --
/// so there is no record type they all share, and this is the boundary where
/// that stops mattering.
external tool: {..} => JSON.t = "%identity"

let tools = [
  tool(scriptTool),
  tool(openLaneTool),
  tool(setTtlTool),
  tool(listTabsTool),
  tool(closeTabsTool),
  tool(closeAllTabsTool),
  tool(destroyLaneTool),
  tool(showBrowserTool),
  tool(hideBrowserTool),
  tool(browserStatusTool),
]

let call = async (name, a) =>
  switch name {
  | "script" =>
    await ensureDaemon()
    let outcome = await Service.run(
      ~source=a->string("source"),
      ~lane=a->string("lane"),
      ~tab=?a->optionalString("tab"),
      ~timeoutS=a->int("timeoutSeconds", ~fallback=60),
      ~checkWall=a->bool("checkWall", ~fallback=true),
    )
    json(Service.encode(outcome))

  | "openLane" =>
    await ensureDaemon()
    await housekeep()
    text(Lanes.openLane())

  | "setTtl" =>
    let lane = a->string("lane")
    let minutes = a->requiredInt("minutes")
    await housekeep(~lane)
    Lanes.setTtl(lane, minutes * 60)
    text(`lane ${lane} expires after ${minutes->Int.toString} min of quiet`)

  | "listTabs" =>
    await ensureDaemon()
    let lane = a->string("lane")
    await housekeep(~lane)
    Lanes.touch(lane)
    let mine = Lanes.tabsOf(lane)
    json(
      JSON.Encode.array(
        (await Targets.pages())
        ->Array.filter(p => mine->Array.includes(p.Models.id))
        ->Array.map(p => JSON.Encode.object(
          Dict.fromArray([
            ("tab", JSON.Encode.string(p.Models.id)),
            ("url", JSON.Encode.string(p.Models.url)),
            ("title", JSON.Encode.string(p.Models.title)),
          ]),
        )),
      ),
    )

  | "closeTabs" =>
    await ensureDaemon()
    let lane = a->string("lane")
    let tabs = a->strings("tabs")
    await housekeep(~lane)
    Lanes.touch(lane)
    text(`closed ${(await Lanes.closeTabs(lane, tabs))->Int.toString} tab(s)`)

  | "closeAllTabs" =>
    await ensureDaemon()
    let lane = a->string("lane")
    await housekeep(~lane)
    Lanes.touch(lane)
    text(`closed ${(await Lanes.closeTabs(lane, Lanes.tabsOf(lane)))->Int.toString} tab(s)`)

  | "destroyLane" =>
    await ensureDaemon()
    let lane = a->string("lane")
    await housekeep(~lane)
    let closed = await Lanes.closeTabs(lane, Lanes.tabsOf(lane))
    Lanes.destroy(lane)
    text(`closed ${closed->Int.toString} tab(s), lane ${lane} is gone`)

  | "showBrowser" =>
    await ensureDaemon()
    let lane = a->string("lane")
    let tab = a->optionalString("tab")
    let waitSeconds = a->int("waitSeconds", ~fallback=0)
    let until =
      a
      ->optionalString("until")
      ->Option.flatMap(Models.parseWaitFor)
      ->Option.getOr(Models.Closed)
    await housekeep(~lane)
    switch a->Dict.get("ttlMinutes")->Option.flatMap(v => v->JSON.Decode.float) {
    | Some(minutes) => Lanes.setTtl(lane, minutes->Float.toInt * 60)
    | None => ()
    }

    Lanes.touch(lane)
    Lanes.claimScreen(lane)
    switch tab {
    | Some(tab) =>
      await Session.use(async session =>
        await Handoff.bringToFront(await Session.pageFor(session, lane, Some(tab)))
      )
    | None => ()
    }

    let presenter = Present.select()
    let how = await presenter.present()
    if a->bool("notifyHuman", ~fallback=false) {
      Notify.select().notify("Agent browser needs you", how)
    }

    if waitSeconds == 0 {
      Lanes.touch(lane)
      text(how)
    } else {
      let waited = switch (until, tab) {
      | (Models.Unblocked, None) => Some("cannot wait on a wall with no tab named")
      | (Models.Unblocked, Some(tab)) =>
        Some(
          await Session.use(async session => {
            let page = await Session.pageFor(session, lane, Some(tab))
            await Handoff.waitUntilUnblocked(page, ~timeoutS=waitSeconds)
          }),
        )
      | (Models.Closed, _) => Some(await Handoff.waitForDismissal(presenter, waitSeconds))
      }
      Lanes.touch(lane)
      text(`${how} -- ${waited->Option.getOr("")}`)
    }

  | "hideBrowser" =>
    let lane = a->string("lane")
    // Sweeps before counting, so the tab count below is what Chrome really has
    // and not what the db last heard: a tab the human closed during the handoff
    // would otherwise be reported back as still open.
    await housekeep(~lane)
    Lanes.touch(lane)
    let gone = Lanes.releaseScreen(lane)
    if gone {
      Present.select().dismiss()
    }

    let screen = gone
      ? "dismissed"
      : `still shown: ${Lanes.screenClaims()->Array.length->Int.toString} other claim(s)`

    // Callers have reached for this one meaning "I am finished with the pages"
    // and then walked away leaving the tabs open, because "hideBrowser" reads
    // like the browser going away. It only ever took the *window* away; the lane
    // and its tabs outlive it, and the only thing that ever closed them was a ttl
    // sweep some minutes later. So when there is anything left open, the return
    // says so and names the tools that do close it, rather than answering
    // "dismissed" to a question the caller did not ask.
    let open_ = Lanes.tabsOf(lane)->Array.length
    text(
      open_ == 0
        ? screen
        : `${screen} -- ${open_->Int.toString} tab(s) still open in this lane; this only ` ++
          "released the screen. If you meant to close the pages, use closeTabs, " ++
          "or destroyLane when you are done with the lane entirely.",
    )

  | "browserStatus" =>
    let presenter = Present.select()
    let (host, port) = Present.endpoint()
    let up = await Browser.isUp()
    let (openTabs, orphaned) = await Lanes.counts()
    json(
      JSON.Encode.object(
        Dict.fromArray([
          ("daemon", JSON.Encode.string(up ? "up" : "down")),
          // How the window is being hidden, which decides whether it can be. The
          // CLI's `status` reported this and nothing else did; ticket 057 moved
          // it here rather than losing it, because a machine that resolved no
          // nested backend starts Chrome *visible* and this is the only line that
          // says so before somebody notices a browser on their desktop.
          ("launch", JSON.Encode.string(Models.backendToString(Launch.select().name))),
          ("presenter", JSON.Encode.string(Models.presenterToString(presenter.name))),
          ("onScreen", JSON.Encode.string(presenter.presented() ? "True" : "False")),
          ("profile", JSON.Encode.string(Config.profileDir())),
          // Named so a black screen is diagnosable: a viewer attached while
          // session reads "stale" is looking at a compositor with nothing in it.
          (
            "session",
            JSON.Encode.string(NestedSessions.live()->Option.isSome ? "live" : "stale"),
          ),
          ("vnc", JSON.Encode.string(`${host}:${port->Int.toString}`)),
          // The only number that reveals a lane you do not own. Without it
          // nothing in this tool can show tabs piling up, since every listing is
          // scoped to the caller. A count, deliberately: ids and owners would be
          // a listing, and a lane's tabs are nobody else's business.
          (
            "tabs",
            JSON.Encode.string(
              `${openTabs->Int.toString} open, ${orphaned->Int.toString} orphan`,
            ),
          ),
          // The one thing a tab count cannot show: a tab that is holding every
          // attach open counts the same as a working one (ticket 042). Asked of
          // every tab, so it costs a websocket round trip each -- this is a
          // diagnostic, and a healthy tab answers in under 10ms.
          (
            "wedged",
            JSON.Encode.string(up ? await Targets.stuckSummary() : "unknown"),
          ),
          (
            "screenClaims",
            JSON.Encode.string(Lanes.screenClaims()->Array.length->Int.toString),
          ),
        ]),
      ),
    )

  | other => Errors.fail(ScriptInvalid, `no tool named ${other}`)
  }

// --- the server -------------------------------------------------------------

let server = Mcp.server(
  {"name": "passenger", "version": "0.1.0"},
  {"capabilities": {"tools": Dict.make()}},
)

server->Mcp.setRequestHandler(Mcp.listToolsRequest, async _ => {"tools": tools})

/// A domain failure has to reach the caller as a message, because nothing
/// downstream catches: the SDK reports an error by its `message` and nothing
/// else. `Errors.rendered` is what carries the code and the remedy into that
/// one string -- which is ticket 057's finding, that every detail written for a
/// CLI that no longer exists had never once reached an agent.
@new external error: string => exn = "Error"

server->Mcp.setRequestHandler(Mcp.callToolRequest, async req =>
  switch await call(req["params"]["name"], args(req)) {
  | result => result
  | exception Errors.Passenger({code, message, detail}) =>
    throw(error(Errors.rendered(code, message, detail)))
  }
)

// Nothing here may write to stdout except the protocol, so every branch that
// says something to a person says it on stderr and exits -- and the one that
// serves says nothing at all.
@val @scope("process") external argv: array<string> = "argv"
@val @scope("process") external exit: int => unit = "exit"

let serve = async () => await server->Mcp.connect(Mcp.stdio())

let main = async () => {
  let args = argv->Array.slice(~start=2, ~end=argv->Array.length)

  // Ahead of the parser, not inside it: this is the viewer server re-execing
  // this same module, never something a person types, and it takes a port
  // rather than the flags a command takes. Keeping it out of `Cli.commands`
  // keeps it out of the usage text, which is where it belongs.
  if !Webserve.serveIfAsked(args) {
    switch Cli.parse(args) {
    | Some(invocation) =>
      switch invocation.command.name {
      | "serve" => await serve()
      | "stop" => exit(await Stop.run(~force=invocation->Cli.flag("force")))
      | _ => exit(2)
      }
    | None =>
      // No command, an unknown one, or a flag it does not take. Reporting it by
      // *starting a server* would be the worst of the options: a person who
      // typed `--help` would watch a process sit on a pipe nobody is reading and
      // conclude it had hung.
      Console.error(Cli.usage())
      exit(2)
    }
  }
}

main()->Promise.ignore
