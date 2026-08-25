// Targets and the live lane seam, against whatever Chrome is already running.
//
// Not a test, and it cannot be one: it needs a browser. The state directory goes
// to a temp path first so this can never touch a real registry.

@module("node:fs") external mkdtempSync: string => string = "mkdtempSync"
@module("node:os") external tmpdir: unit => string = "tmpdir"

let main = async () => {
  Config.stateDir := mkdtempSync(tmpdir() ++ "/passenger-live-")

  let pages = await Targets.pages()
  let first = pages->Array.get(0)
  Console.log(
    `pages: ${pages->Array.length->Int.toString} | first title: ` ++
    first->Option.map(p => p.Models.title)->Option.getOr("(none)"),
  )
  let socket = first->Option.map(p => p.Models.websocketUrl)->Option.getOr("")
  Console.log(
    "socket looks right: " ++
    (socket->String.match(%re("/^ws:\/\/127\.0\.0\.1:\d+\/devtools\/page\//"))->Option.isSome
      ? "true"
      : "false"),
  )

  Console.log("openers: " ++ JSON.stringifyAny(await Targets.openers())->Option.getOr("?"))
  Console.log("browserSocket: " ++ (await Targets.browserSocket())->String.slice(~start=0, ~end=40))
  Console.log("stuckSummary: " ++ (await Targets.stuckSummary()))

  let (open_, orphaned) = await Lanes.counts()
  Console.log(
    `counts through the live seam: open=${open_->Int.toString} orphaned=${orphaned->Int.toString}`,
  )
  let swept = await Lanes.sweep()
  Console.log(
    `sweep collected: ${swept->Array.length->Int.toString} | orphan now holds ` ++
    Lanes.tabsOf(Lanes.orphan)->Array.length->Int.toString,
  )
}

main()->Promise.ignore
