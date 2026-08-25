// Attaching, lane-scoped tabs, and what Playwright's handles serialise to.
//
// Not a test: it needs a browser. The handle half is the measurement the
// decision in `Script.crossable` rests on -- there is no rule refusing them any
// more, so what matters is that each one stays small and says its own name.

@module("node:fs") external mkdtempSync: string => string = "mkdtempSync"
@module("node:os") external tmpdir: unit => string = "tmpdir"

let say = (label, value) => Console.log(`${label}: ${value}`)
let yn = b => b ? "true" : "false"

let handles = (session: Session.t, page) => [
  ("page", page->Obj.magic),
  ("context", session.context->Obj.magic),
  ("browser", session.browser->Obj.magic),
  ("locator", Pw.locator(page, "body")->Obj.magic),
  ("request", Pw.request(page)->Obj.magic),
  ("keyboard", Pw.keyboard(page)->Obj.magic),
  ("mouse", Pw.mouse(page)->Obj.magic),
  ("frameLocator", Pw.frameLocator(page, "iframe")->Obj.magic),
]

let main = async () => {
  Config.stateDir := mkdtempSync(tmpdir() ++ "/passenger-live-")
  say("isUp", yn(await Targets.isUp()))

  let lane = Lanes.openLane()
  say("lane", lane)

  let session = await Session.open_()
  say("pages seen", session.context->Pw.pages->Array.length->Int.toString)

  let page = await Session.page(session, lane)
  let tab = await Session.targetId(session, page)
  say("tab", `${tab} | owner: ${Lanes.owner(tab)->Option.getOr("(none)")}`)

  let same = await Session.pageFor(session, lane, Some(tab))
  say("pageFor returned the same tab", yn((await Session.targetId(session, same)) == tab))
  let again = await Session.page(session, lane)
  say("blank tab reused", yn((await Session.targetId(session, again)) == tab))

  switch await Session.pageFor(session, lane, Some("deadbeef")) {
  | _ => say("pageFor a foreign tab", "NO ERROR (wrong)")
  | exception Errors.Passenger({code, message, detail}) =>
    say("pageFor a foreign tab", Errors.rendered(code, message, detail))
  }

  // Every handle kind, serialised. `_type` or `_apiName` in there is what the
  // skill tells a caller to look for, so this fails loudly if a future
  // Playwright stops labelling them.
  handles(session, page)->Array.forEach(((name, handle)) => {
    let json = switch JSON.stringifyAny(handle) {
    | Some(text) => text
    | None => ""
    | exception _ => "THROWS"
    }
    let labelled = json->String.match(%re("/\"_(type|apiName)\":/"))->Option.isSome
    Console.log(
      `  handle ${name->String.padEnd(14, " ")} ${json
        ->String.length
        ->Int.toString
        ->String.padStart(5, " ")} B | ` ++ (labelled ? "names itself" : "UNLABELLED (wrong)"),
    )
  })

  say("closeOthers closed", (await Session.closeOthers(session, lane, page))->Int.toString)
  say("closed on destroy", (await Lanes.closeTabs(lane, Lanes.tabsOf(lane)))->Int.toString)
  await Session.dispose(session)
  say("detached; chrome still up", yn(await Targets.isUp()))
}

main()->Promise.ignore
