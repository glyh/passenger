// Imperative shell: Chrome daemon lifecycle and CDP attach.
//
// Chrome is launched here rather than through a persistent-context helper so the
// window outlives any single command: you solve a challenge once, and every later
// call reuses that same warm, logged-in session.
//
// Launch args are deliberately minimal. Every extra flag is a way to look unlike
// a normal Chrome start, and --enable-automation (the flag that actually sets
// navigator.webdriver) is simply never passed.
//
// The attach half of this module is `Session`; only the lifecycle is here. That
// split existed on the C# side too, as a static class and a disposable one.

let startupPolls = 60
let pollIntervalMs = 500

/// Whether the browser is answering at all. `Targets.isUp` holds it, for the
/// reason the comment there gives: `Session` needs the same question, and
/// ReScript has no circular module dependencies.
let isUp = Targets.isUp

let portTaken = () => NestedSessions.isListening("127.0.0.1", Config.cdpPort.contents)

/// Give Chrome its own toolbar back, by taking it out of fullscreen.
///
/// This existed because cage was a kiosk compositor: it fullscreened the client
/// it started, and a fullscreen Chrome hides its tab strip and toolbar. Nothing
/// chose that -- it fell out of the mechanism picked for hiding the window -- and
/// it landed on the one moment the window is looked at. A human handed the
/// browser to solve a captcha or finish a login could click inside the page and
/// nothing else: no address bar to read or type into, no back button out of a
/// redirect, no tabs.
///
/// Ticket 063 removed that cause: sway does not fullscreen what it starts, so on
/// a fresh session there is now nothing here to undo. It is kept anyway, and
/// stops being a workaround: a *page* can call the Fullscreen API, and a human
/// can press F11, so "the browser a person is handed is windowed" is an invariant
/// worth holding rather than a side effect worth cancelling.
///
/// Windowed is also the more ordinary of the two shapes for a real browser to be
/// in: a fullscreen window reports outerHeight equal to the screen with no
/// browser UI accounting for the difference.
///
/// Cheap and idempotent, so it runs on every start and again before every handoff
/// (see `Present.prepared`). When the window was never fullscreen -- `--visible`,
/// or no nested backend -- the state is read and nothing is written.
let unfullscreen = async () =>
  if await isUp() {
    switch await Session.use(async session =>
      switch session.context->Pw.pages->Array.get(0) {
      // No target to name a window by; nothing to fix.
      | None => ()
      | Some(page) =>
        let targetId = await Session.targetId(session, page)
        let control = await session.browser->Pw.newBrowserCDPSession
        let window =
          await control->Pw.sendWith("Browser.getWindowForTarget", {"targetId": targetId})
        let bounds =
          window
          ->JSON.Decode.object
          ->Option.flatMap(o => o->Dict.get("bounds"))
          ->Option.flatMap(b => b->JSON.Decode.object)
        let state =
          bounds
          ->Option.flatMap(o => o->Dict.get("windowState"))
          ->Option.flatMap(v => v->JSON.Decode.string)
          ->Option.getOr("")
        if state == "fullscreen" {
          let windowId =
            window
            ->JSON.Decode.object
            ->Option.flatMap(o => o->Dict.get("windowId"))
            ->Option.flatMap(v => v->JSON.Decode.float)
            ->Option.getOr(0.0)
          let _ = await control->Pw.sendWith(
            "Browser.setWindowBounds",
            {"windowId": windowId, "bounds": {"windowState": "normal"}},
          )
        }
      }
    ) {
    | () => ()
    // The daemon is up and calls work; only the toolbar is missing. Raising here
    // would report a working browser as a failed start.
    | exception _ => ()
    }
  }

/// Launch the daemon. Returns a one-line description of what came up.
///
/// The C# door took a `detach` flag; there is nothing left for it to decide.
/// That flag chose whether to drain the child's pipes, and this runtime's
/// detached spawn sends them to /dev/null outright -- which is not merely
/// equivalent but required, since a child holding this process's stdout holds
/// the JSON-RPC transport. No caller ever passed false.
let start = async (~hidden=true) =>
  if await isUp() {
    // A browser left running by a previous client still deserves a reaper even
    // when its own died with something, so "already running" summons too --
    // and summons, not assumes: the pid record is what keeps this from
    // stacking a second one beside a live watcher.
    Reaper.summon()
    `already running on ${Config.cdpUrl()}`
  } else if await portTaken() {
    Errors.fail(
      PortInUse,
      `port ${Config.cdpPort.contents->Int.toString} is in use by something else`,
    )
  } else if Launch.which(Config.chromeBin.contents)->Option.isNone {
    Errors.fail(ChromeNotFound, `${Config.chromeBin.contents} not found on PATH`)
  } else {
    // A previous session whose Chrome died leaves the compositor and wayvnc
    // behind, still holding the VNC port. Left alone, the session starting here
    // cannot claim that port and the stale server keeps answering viewers with
    // the empty compositor it is still attached to.
    let reaped = await NestedSessions.reapStale()
    // Every row in the lane registry names a CDP target id from the browser that
    // just went away, and Chrome never hands those ids out again. Kept, they
    // would make `listTabs` promise tabs that cannot exist.
    Lanes.reset()

    Fs.mkdirp(Config.profileDir())
    let argv = [
      Config.chromeBin.contents,
      `--remote-debugging-port=${Config.cdpPort.contents->Int.toString}`,
      `--user-data-dir=${Config.profileDir()}`,
      "--no-first-run",
      "--no-default-browser-check",
    ]

    let backend = Launch.select()
    switch (hidden, backend.name) {
    | (true, NoBackend) =>
      // Silently launching a visible window would defeat the point of this tool,
      // and the caller would never know. Make them say so explicitly.
      Errors.fail(
        CannotHide,
        "asked to start hidden, but nothing here can hide a window",
        ~detail="install sway + wayvnc (or `nix develop`), " ++
        "or start it with --visible to accept a visible window",
      )
    | _ => ()
    }

    let argv = if hidden {
      backend.prepare()
      argv->Array.concat([
        `--class=${Launch.wmClass}`,
        // Off-screen windows get their timers throttled, which stalls the very
        // challenge scripts we need to run. None are visible to page JS.
        "--disable-background-timer-throttling",
        "--disable-backgrounding-occluded-windows",
        "--disable-renderer-backgrounding",
      ])
    } else {
      argv
    }
    let argv = argv->Array.concat(["about:blank"])

    let plan = hidden ? await backend.plan(argv) : await Launch.noOp.plan(argv)
    let program = plan.argv->Array.get(0)->Option.getOr("")
    let rest = plan.argv->Array.slice(~start=1, ~end=plan.argv->Array.length)
    let spawned = Proc.detach(~env=plan.env, program, rest)
    if spawned->Option.isNone {
      Errors.fail(
        DaemonStartFailed,
        "could not start chrome",
        ~detail=plan.argv->Array.join(" "),
      )
    }

    let came = await Poll.until(~times=startupPolls, ~everyMs=pollIntervalMs, isUp)

    if came {
      await unfullscreen()
      // The reaper is summoned only after Chrome answers, so what it watches
      // is what actually came up -- and its environment is this process's,
      // which is this browser's, by construction (ticket 076).
      Reaper.summon()
      let state = hidden ? "hidden" : "visible"
      let line = `chrome up on ${Config.cdpUrl()} [${state}] (profile: ${Config.profileDir()})`
      // A reap that could not finish is said out loud here: it means something is
      // still holding the old VNC port, so this session advertises a different one
      // than the last.
      switch reaped {
      | Some(note) => `${line}\n${note}`
      | None => line
      }
    } else {
      Errors.fail(
        DaemonStartFailed,
        "chrome did not expose CDP in time",
        ~detail=plan.argv->Array.join(" "),
      )
    }
  }

/// Stop this tool's browser, and nothing else. Returns what would not go.
///
/// The body moved to `Reaper.takeDown` (ticket 076) so the idle reaper's
/// watchdog could share it without importing this module -- Playwright hangs
/// off `Session`, which hangs off here. Still scoped to the recorded session
/// and to our own profile directory; the move also completed the inventory,
/// since `stop` used to leave the viewer window and the page server behind.
let stop = async () => await Reaper.takeDown()

// The seam `Present` declares, closed here: presenting fullscreens nothing but
// has to undo it, and the body is Playwright's. See `Present.unfullscreen`.
Present.unfullscreen := unfullscreen
