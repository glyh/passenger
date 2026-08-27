// The one thing a human types.
//
// Ticket 057 deleted the CLI: nobody had ever run it, and every verb on it but
// this one duplicated a tool at the door that actually gets used. What could not
// go is the exit from a wedged Chrome. `Browser.stop` is the only one, and making
// it a tool was rejected on the rule this codebase has applied twice already --
// `hide --force`, and 040's refcounted screen -- that destructive things a human
// should own do not get an agent tool. An agent that hits a timeout and helpfully
// restarts Chrome costs the owner every login on the machine.
//
// So it lives here, handled before the server is connected.
// `Webserve.serveIfAsked` set that pattern; this follows it with one difference
// in shape. `--serve-viewer` is a flag because nothing but this process ever
// types it. `stop` is a verb because a person does.
//
// **stdout is this file's to use.** Everywhere else in this project it belongs to
// the protocol, and a stray line there corrupts the JSON-RPC stream. Reaching
// here means no server was started and none will be: the process says one thing
// and exits.

/// What is about to be lost, before it is lost.
///
/// Both halves are said because they fail differently. A screen claim means a
/// person is looking at the window right now, quite possibly mid-captcha -- 040
/// built the refcount so one lane could not take the window from another lane's
/// human, and this is the same interruption from outside the lanes entirely. Tabs
/// are the quieter loss: a solved login with no viewer open looks like nothing at
/// all and is exactly what the warm session is for.
let refusal = (claims, occupied) => {
  let lines = []
  if claims->Array.length > 0 {
    lines->Array.push(
      `the browser is on screen for ${claims->Array.length->Int.toString} lane(s): ` ++
      claims->Array.join(", ") ++
      " -- somebody may be mid-handoff",
    )
  }

  if occupied->Array.length > 0 {
    let total = occupied->Array.reduce(0, (sum, (_, tabs)) => sum + tabs)
    lines->Array.push(
      `${total->Int.toString} tab(s) open in ${occupied->Array.length->Int.toString} lane(s): ` ++
      occupied
      ->Array.map(((lane, tabs)) => `${lane} (${tabs->Int.toString})`)
      ->Array.join(", "),
    )
  }

  lines->Array.push(
    "stopping loses the warm logged-in session; `passenger stop --force` does it anyway",
  )
  lines->Array.join("\n")
}

/// Stop the browser, or refuse and say what would have been lost. Returns the
/// exit status.
let run = async (~force) => {
  let _ = await Lanes.sweep()

  // Only a running browser has anything to lose, and only it can be asked.
  // `occupied` reaches Chrome and returns empty when it cannot, but
  // `screenClaims` is sqlite alone: a Chrome that died leaves its claim rows
  // behind until the next start drops the tables, and refusing on those would
  // wedge the one command that clears a wedge.
  let up = await Browser.isUp()
  // A claim `passenger show` left behind after its window was closed by hand is
  // not somebody mid-handoff, and refusing on one is the exact wedge this
  // command exists to clear. See `Screen.dropStaleHumanClaim`.
  Screen.dropStaleHumanClaim(Present.select())
  let claims = up ? Lanes.screenClaims() : []
  let occupied = up ? await Lanes.occupied() : []

  if !force && (claims->Array.length > 0 || occupied->Array.length > 0) {
    Console.error(refusal(claims, occupied))
    1
  } else {
    Console.log((await Browser.stop())->Option.getOr("stopped"))
    0
  }
}
