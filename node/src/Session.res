// Imperative shell: attaching Playwright to the running Chrome, and handing
// back pages.
//
// The C# side wrote this as a class with an `OpenAsync` factory and
// `IAsyncDisposable`, because attaching is async and a constructor cannot be.
// Here it is a record and a set of functions, which is the same shape with the
// ceremony removed -- `open_` is the factory, `dispose` is the `await using`.
//
// Two things the .NET port carried do not survive, and both are the runtime
// rather than the design:
//
//   * There is no driver process. .NET's Playwright talks to a Node driver it
//     spawns, so a wedged attach could be cleared by disposing the driver and
//     making a new one (`RestartDriverAsync`). Here Playwright *is* the process,
//     so there is nothing to restart -- what has to be released instead is the
//     abandoned attach itself, and the only handle on it is the deadline
//     Playwright takes.
//   * That deadline is worth passing here where it was not worth passing there.
//     Ticket 012 measured .NET's `ConnectOverCDPAsync` timeout not being honoured
//     by a driver already wedged mid-attach; in this runtime the same option is
//     a `progress.race` in the same process, with cleanup that closes the CDP
//     transport when it aborts. That is a reading of the library, not a
//     measurement against a wedged tab, so our own race stays as the thing that
//     guarantees this function returns.

type t = {browser: Pw.browser, context: Pw.context}

/// Our own deadline, independent of whatever the library does with its own.
exception Timeout

/// One attach attempt, bounded.
///
/// The timer is cleared on both exits rather than left to fire into a settled
/// race. An uncleared one holds the event loop open for the whole attach budget
/// after a fast attach has already answered, which is invisible in a long-lived
/// server and would hang a one-shot script for fifteen seconds.
let connect = async () => {
  let ms = Config.attachTimeoutS.contents * 1000
  let timer = ref(None)
  let deadline = Promise.make(
    (_resolve, reject) => timer := Some(Timers.setTimeout(() => reject(Timeout), ms)),
  )
  let clear = () => timer.contents->Option.forEach(Timers.clearTimeout)
  let attaching = Pw.connectOverCDPWith(Pw.chromium, Config.cdpUrl(), {timeout: ms})
  try {
    let browser = await Promise.race([attaching, deadline])
    clear()
    browser
  } catch {
  | e =>
    clear()
    throw(e)
  }
}

/// Attach -- and if a stuck tab is holding the attach open, free it.
///
/// Attaching initialises every tab that is already open and waits for all of
/// them. So one tab left mid-navigation used to hang every later call, forever,
/// and every entry point into this tool starts with an attach: the whole thing
/// bricked until a human found the tab. Measured at 75s and still counting.
///
/// The rescue cannot use Playwright, since Playwright is what is stuck. It goes
/// to the browser process directly instead (see `Targets`), and stops the
/// pending navigation rather than closing the tab -- whatever document that tab
/// already had is usually the one a human was reading.
///
/// Two shapes of tab do this, and they need different remedies; `Targets` holds
/// the difference. Both are freed here, and neither is closed.
let attach = async () =>
  switch await connect() {
  | browser => browser
  | exception Timeout =>
    let stuck = await Targets.unstick()
    if stuck->Array.length > 0 {
      // Lanes partition ownership, not availability: one attach initialises
      // every open tab, so a tab wedged in any lane hangs every lane, and
      // freeing it can stop a navigation that another lane is in the middle of.
      // Ticket 012 closed on exactly that trade, a year before lanes existed. It
      // cannot be prevented while one profile means one Chrome -- so it is said
      // out loud instead, and a lane whose call died learns why.
      //
      // stderr, not stdout: this process speaks JSON-RPC on stdout and a stray
      // line there is a protocol error, not a log.
      Console.error(`   freed a wedged tab in ${Lanes.lanesOf(stuck)}`)
    }

    switch await connect() {
    | browser => browser
    | exception Timeout =>
      throw(
        Errors.Passenger({
          code: AttachTimeout,
          message: `could not attach to chrome within ${Config.attachTimeoutS.contents->Int.toString}s, twice`,
          // Says what was *checked*, not what is therefore true. The old line
          // asserted the negative -- "so this is something else" -- on the
          // strength of a probe that knew about one of the two wedges, and sent
          // callers to `passenger stop`, which throws away the warm logged-in
          // session this whole tool exists to keep (ticket 042).
          detail: Some(
            stuck->Array.length > 0
              ? `stuck in ${Lanes.lanesOf(stuck)}: ` ++
                stuck->Array.map(p => p.Models.url)->Array.join(", ")
              : "every tab answered its renderer probe and every one of them " ++
                "holds a document, so neither wedge this knows how to free is " ++
                "present; `browserStatus` says what is open, and asking the " ++
                "human to run `Passenger.Mcp stop` restarts chrome at the cost " ++
                "of the warm session",
          ),
        }),
      )
    }
  }

let open_ = async () => {
  if !(await Targets.isUp()) {
    // No remedy, because there is no command that is one. The daemon starts on
    // demand at every tool, so reaching this means the start failed or Chrome
    // died mid-call -- ticket 057, which deleted the `serve` this line used to
    // name.
    Errors.fail(DaemonNotRunning, `chrome is not answering on ${Config.cdpUrl()}`)
  }

  let browser = await attach()
  {browser, context: browser->Pw.contexts->Array.getUnsafe(0)}
}

/// The tab's CDP id -- the handle a caller holds between calls.
///
/// Not the Playwright page object, which lives only as long as this attach, and
/// not the URL, which changes under a script's feet.
let targetId = async (session, page) => {
  let cdp = await session.context->Pw.newCDPSession(page)
  (await cdp->Pw.send("Target.getTargetInfo"))
  ->JSON.Decode.object
  ->Option.flatMap(o => o->Dict.get("targetInfo"))
  ->Option.flatMap(t => t->JSON.Decode.object)
  ->Option.flatMap(o => o->Dict.get("targetId"))
  ->Option.flatMap(v => v->JSON.Decode.string)
  ->Option.getOr("")
}

let blankUrls = ["about:blank", "chrome://newtab/"]

/// A tab in this lane -- a blank one it already owns, or a new one.
///
/// Reuse is lane-scoped, and that is the whole point. It used to search every
/// open tab for an `about:blank`, so one caller's call could be handed the blank
/// tab another caller had opened a moment ago and not yet navigated: two
/// callers, one tab, and neither aware of the other.
let page = async (session, lane, ~reuse=true) => {
  let mine = reuse ? Lanes.tabsOf(lane) : []
  let found = ref(None)
  let blanks = session.context->Pw.pages->Array.filter(p => blankUrls->Array.includes(Pw.url(p)))
  for i in 0 to blanks->Array.length - 1 {
    if found.contents->Option.isNone {
      let existing = blanks->Array.getUnsafe(i)
      if mine->Array.includes(await targetId(session, existing)) {
        found := Some(existing)
      }
    }
  }

  switch found.contents {
  | Some(existing) => existing
  | None =>
    let opened = await session.context->Pw.newPage
    Lanes.adopt(await targetId(session, opened), lane)
    opened
  }
}

/// The tab a call named, if this lane owns it, else a blank one.
///
/// Ownership is checked before the browser is: a tab belonging to another lane
/// and a tab that never existed have to be the same answer, or the refusal
/// itself tells the caller that somebody else is holding it.
let pageFor = async (session, lane, tab) =>
  switch tab {
  | None => await page(session, lane)
  | Some(tab) =>
    let ownedHere = switch Lanes.owner(tab) {
    | Some(owner) => owner == lane
    | None => false
    }
    if !ownedHere {
      throw(Errors.tabNotFound(~tab, ~lane, ~openTabs=Lanes.tabsOf(lane)))
    }

    let found = ref(None)
    let open_ = session.context->Pw.pages
    for i in 0 to open_->Array.length - 1 {
      if found.contents->Option.isNone {
        let candidate = open_->Array.getUnsafe(i)
        if await targetId(session, candidate) == tab {
          found := Some(candidate)
        }
      }
    }

    switch found.contents {
    // Closed, or from a browser that has restarted since. Either way the caller
    // is holding a handle to something gone, and needs to know which of its own
    // tabs there are rather than a bare failure.
    | None => throw(Errors.tabNotFound(~tab, ~lane, ~openTabs=Lanes.tabsOf(lane)))
    | Some(page) => page
    }
  }

/// Close this lane's other tabs. Returns how many were closed.
///
/// Was `close_other_tabs`, which closed every tab in the browser except one --
/// the global sweep that made one caller's cleanup another's interrupted call.
/// It kept a tab back because Chrome exits when it loses its last one; that
/// invariant now lives in `Lanes.closeTabs`, which every closing path goes
/// through.
let closeOthers = async (session, lane, keep) => {
  let kept = await targetId(session, keep)
  await Lanes.closeTabs(lane, Lanes.tabsOf(lane)->Array.filter(t => t != kept))
}

/// Detach only. Closing the browser would kill the daemon and throw away the
/// session we went to the trouble of warming up.
let dispose = async session =>
  switch await session.browser->Pw.closeBrowser {
  | () => ()
  | exception _ => ()
  }
