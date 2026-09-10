// Imperative shell: putting the hidden browser in front of a human.
//
// Separate from how Chrome is launched. wayvnc is always running inside the
// nested compositor, serving the session over a websocket; presenting just means
// giving someone a way to look at it, and that differs by where the tool is
// deployed:
//
//   local  open the viewer page in a chromeless window of the host's browser
//   web    hand back the URL to open wherever the human actually is -- the only
//          option that works from a container with no display of its own
//   none   nothing can show it; say so rather than pretending
//
// There is no VNC client here any more. The viewer is a page served to the host's
// own browser, which is both lighter than every native client that would do --
// 1.8 MB of noVNC against 1.2 GiB for the lightest native one that works -- and
// the only one of them that gets the size right by itself: it asks for the
// framebuffer its window needs and keeps asking as the window changes.
//
// Opening it in app mode is what makes it read as a window rather than a browser
// tab: no tab strip, no address bar, and the page itself is the screen, edge to
// edge.
//
// Every URL reported from here has been fetched before it was reported. This is a
// handoff to a *human*, and the cost of handing over a broken page is that the
// person stares at an error and reports the tool as broken -- which is exactly
// what ticket 058 was. `Webserve.ensure` does the fetching, so the check is one
// request against a local server on a call that already blocks. Note the limit:
// whether the page *renders* stays the human's judgement; whether it was *served*
// is a fact this tool can have, and now does.

open Models

type presenter = {
  name: presenterName,
  /// Whether `presented` is a real observation or a standing guess. Only a
  /// presenter that can see its own window may be waited on: the human closing
  /// the viewer is the one completion signal this tool does not have to infer,
  /// and a presenter that always answers false would report it the instant the
  /// wait began (ticket 018).
  observesPresence: bool,
  available: unit => bool,
  present: unit => promise<string>,
  dismiss: unit => unit,
  presented: unit => bool,
}

// Chrome first because it is already this tool's dependency, then the common
// Chromium builds: app mode is a Chromium feature, and a browser without it would
// open a tab with a URL bar around the screen.
let browsers = [
  "google-chrome-stable",
  "chromium",
  "chromium-browser",
  "brave-browser",
  "microsoft-edge-stable",
]

let openPolls = 20
let pollIntervalMs = 250

/// Where the *live* session is listening.
///
/// Read from the session record rather than from settings, because the port a
/// session ends up on is claimed when it starts. Pointing a viewer at the
/// configured port instead is how a viewer ends up attached to a previous, dead
/// session and shows nothing but black.
let endpoint = () =>
  switch NestedSessions.live() {
  | Some(live) => (live.vncHost, live.vncPort)
  | None => (Config.vncHost.contents, Config.vncPort.contents)
  }

/// The viewer page, told which session to connect to.
let pageUrl = () => {
  let (host, port) = endpoint()
  `${Config.viewerUrl()}?ws=${host}:${port->Int.toString}`
}

/// Putting Chrome back into a window, filled in by `Browser` when it loads.
///
/// A seam rather than a call, and the same one `Lanes.chrome` is: the body
/// lives in `Browser`, which is Playwright, and Playwright is exactly what the
/// idle reaper's watchdog cannot afford to import (ticket 076) -- it reaches
/// this module for `dismiss` and nothing else. Presenting is always downstream
/// of `Browser`, so by the time any `present()` runs the real one is in here;
/// a watchdog that never presents keeps the no-op and never loads Playwright.
let unfullscreen: ref<unit => promise<unit>> = ref(async () => ())

/// Make the nested session fit to be looked at, and say what changed.
///
/// Two things a human needs that a hidden browser does not. The output takes the
/// host screen's density -- only the density: the size belongs to the viewer,
/// which asks for it over RFB as soon as it connects and again whenever its
/// window changes. And Chrome is put back into a window if anything has
/// fullscreened it -- which cage used to do to every session, and which a page or
/// an F11 can still do -- since fullscreen is what hides the address bar and back
/// button from the person being asked to use them.
///
/// Done here rather than only at startup so that a session started before this
/// existed, or one somehow re-fullscreened, is still handed over with its
/// controls.
let prepared = async live =>
  switch live {
  | None => ""
  | Some(session) =>
    await unfullscreen.contents()
    switch Geometry.fit(session.NestedSessions.waylandDisplay) {
    | Some(change) => `, ${change}`
    | None => ""
    }
  }

let noViewer = (message, detail) =>
  Errors.Passenger({code: NoPresenter, message, detail: Some(detail)})

// --- local: a chromeless window on this machine ------------------------------

let viewerBrowser = () =>
  switch Config.viewerBrowser.contents {
  | Some(chosen) => [chosen]
  | None => browsers
  }->Array.find(b => Launch.which(b)->Option.isSome)

/// Is *our* window open?
///
/// Tracked by the pid we spawned, which is only meaningful because the window
/// runs on a profile of its own -- see `Config.viewerProfile`.
let windowPresented = () => NestedSessions.viewerPid()->Option.isSome

let viewerArgs = () => [
  `--app=${pageUrl()}`,
  `--user-data-dir=${Config.viewerProfile()}`,
  "--no-first-run",
  "--no-default-browser-check",
  "--class=passenger-viewer",
]

/// Start the window and wait for it to be up, or say it never was.
let openWindow = async browser => {
  let args = viewerArgs()
  let failed = () => noViewer("viewer window did not open", `${browser} ${args->Array.join(" ")}`)
  switch Proc.detach(browser, args) {
  | None => throw(failed())
  | Some(pid) =>
    NestedSessions.recordViewer(pid)
    // The window is never up on the first look, so this always waits once --
    // which is `Poll.until`'s shape read backwards, and cheaper than a check
    // that cannot succeed.
    await Timers.sleep(pollIntervalMs)
    if !(await Poll.until(~times=openPolls, ~everyMs=pollIntervalMs, async () => windowPresented())) {
      NestedSessions.clearViewer()
      throw(failed())
    }
  }
}

let window = {
  name: Local,
  observesPresence: true,
  available: () => viewerBrowser()->Option.isSome && Webserve.novncRoot()->Option.isSome,
  presented: windowPresented,
  present: async () => {
    let live = NestedSessions.live()
    if windowPresented() {
      `viewer already open${await prepared(live)}`
    } else {
      switch viewerBrowser() {
      | None => throw(noViewer("no browser to open", `open ${pageUrl()} in any browser`))
      | Some(browser) =>
        // Refused rather than shown: with no live session there is nothing behind
        // the port, and a viewer opened onto it shows an empty rectangle that
        // looks exactly like a broken stack.
        if live->Option.isNone {
          throw(
            noViewer(
              "no live browser session",
              "the daemon starts on demand, so this is one that failed or " ++
              "died; `browserStatus` says which",
            ),
          )
        }

        if !(await Webserve.ensure(Config.novncPort.contents)) {
          throw(noViewer("cannot serve the viewer", "no noVNC found; set PASSENGER_NOVNC"))
        }

        let change = await prepared(live)
        await openWindow(browser)
        `opened ${browser} on ${pageUrl()}${change}`
      }
    }
  },
  /// Close only the window this tool opened.
  ///
  /// The old `pkill -x` swept up every VNC client on the machine, including
  /// remote desktops that had nothing to do with this browser.
  dismiss: () => {
    switch NestedSessions.viewerPid() {
    | Some(pid) => Posix.kill(pid, Posix.sigterm)
    | None => ()
    }
    NestedSessions.clearViewer()
  },
}

// --- web: a URL for a human to open wherever they are -------------------------

/// Whether anyone actually opened it is unknowable from here, so `presented`
/// stays false and `dismiss` does nothing -- better than inventing a state we
/// cannot observe.
let link = {
  name: Web,
  observesPresence: false,
  /// Only if the page can actually be served. Handing back a URL that answers
  /// nothing would be the same silent lie as launching a visible window and
  /// calling it hidden.
  available: () => Webserve.novncRoot()->Option.isSome,
  presented: () => false,
  present: async () => {
    let live = NestedSessions.live()
    if !(await Webserve.ensure(Config.novncPort.contents)) {
      throw(noViewer("cannot serve the viewer", "no noVNC found; set PASSENGER_NOVNC"))
    }

    `open ${pageUrl()} to take over the browser${await prepared(live)}`
  },
  dismiss: () => (),
}

// --- none ---------------------------------------------------------------------

let none = {
  name: NoPresenter,
  observesPresence: false,
  available: () => true,
  presented: () => false,
  /// Say what is actually available rather than just refusing.
  ///
  /// wayvnc is listening whenever the nested compositor is up, so a browser
  /// pointed at any noVNC installation can still reach it -- from another
  /// machine, or a phone. It speaks websocket rather than raw RFB, though, so a
  /// native VNC client is not the fallback it used to be.
  present: async () => {
    let (host, port) = endpoint()
    `no viewer: nothing here can serve the noVNC page. wayvnc is ` ++
    `listening on ws://${host}:${port->Int.toString} -- point a noVNC at it`
  },
  dismiss: () => (),
}

let build = name =>
  switch name {
  | Local => window
  | Web => link
  | NoPresenter => none
  }

/// Explicit choice wins; otherwise the first mechanism that really exists.
///
/// Each candidate is asked whether it is available, including the link one -- an
/// unconditional fallback would hand back a URL with nothing serving it, which is
/// a worse answer than admitting there is no viewer.
let select = () =>
  switch Config.presenter.contents {
  | Some(chosen) => build(chosen)
  | None =>
    switch [window, link]->Array.find(c => c.available()) {
    | Some(candidate) => candidate
    | None => none
    }
  }

/// Drop the human's claim if the window it stands for is gone.
///
/// Nothing releases it otherwise: the reserved lane has no TTL, so a person who
/// opens the viewer with `show` and then closes it with the mouse -- which is
/// the obvious way to close a window -- leaves a claim behind forever. The cost
/// is not hypothetical: it is `passenger stop` refusing with "the browser is on
/// screen for 1 lane(s): human -- somebody may be mid-handoff" when nothing is
/// on screen and nobody is anywhere near a handoff.
///
/// Only for presenters that can see their own window. The `web` one reports
/// `presented() == false` always, and treating that as "the window is gone"
/// would drop the claim the instant after it was made.
///
/// Lives here rather than in `Screen` (where it was written) because three
/// callers ask it and one of them is the idle reaper's watchdog, which must
/// not reach this module through `Screen`'s import of `Browser` -- the one
/// path along which Playwright would reach the reaper (ticket 076).
let dropStaleHumanClaim = presenter =>
  if (
    presenter.observesPresence &&
    !presenter.presented() &&
    Lanes.screenClaims()->Array.includes(Lanes.human)
  ) {
    Lanes.releaseScreen(Lanes.human)->ignore
  }
