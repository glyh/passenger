// The two things a human types about the window.
//
// `stop` was the whole CLI after ticket 057, on the rule that a destructive
// thing a person should own does not get an agent tool. These are the other
// side of that rule, and the reason they were missing rather than declined:
// every way to put the browser on screen ran through `showBrowser`, which needs
// a lane, and a person sitting at their own machine does not have one. So
// looking at the browser required either an agent willing to ask on their
// behalf or a hand-run `chromium --app=...` against a URL they had to work out.
//
// `hide --force` is named in `Stop.res` as one of the two precedents for
// keeping destructive verbs off the tool list. It is here now, where a human is
// the one holding it, and it does what an agent must not: takes the window down
// while other lanes still claim it.
//
// **stdout is this file's to use**, for the same reason `Stop.res` says it is:
// reaching here means no server was started and none will be.

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
let dropStaleHumanClaim = presenter =>
  if (
    presenter.Present.observesPresence &&
    !presenter.presented() &&
    Lanes.screenClaims()->Array.includes(Lanes.human)
  ) {
    Lanes.releaseScreen(Lanes.human)->ignore
  }

/// Put the browser on screen for the person at this terminal.
///
/// Claims under the reserved `human` lane rather than presenting bare. The
/// screen is refcounted (ticket 040), so a presenter with no claim behind it is
/// dismissed by whichever agent calls `hideBrowser` next -- which, for someone
/// halfway through a login, is the window vanishing for no reason they can see.
///
/// The claim is dropped again if the viewer never opened. A claim standing for a
/// window that does not exist is worse than none: it is what would then refuse
/// an agent's `hideBrowser` forever, with nothing on screen to justify it.
let show = async () => {
  // Same as the tools do it: the daemon starts on demand, and a person typing
  // `show` on a cold machine means the same thing by it as an agent does.
  if !(await Browser.isUp()) {
    (await Browser.start())->ignore
  }

  let _ = await Lanes.sweep()
  let presenter = Present.select()
  dropStaleHumanClaim(presenter)
  Lanes.claimScreen(Lanes.human)
  switch await presenter.present() {
  | how =>
    Console.log(how)
    0
  | exception Errors.Passenger({code, message, detail}) =>
    Lanes.releaseScreen(Lanes.human)->ignore
    Console.error(Errors.rendered(code, message, detail))
    1
  }
}

/// What is being interrupted, before it is interrupted.
///
/// Said in the same shape as `Stop.refusal` and for the same reason: a lane
/// holding the screen means an agent asked a person for help and may still be
/// waiting on them. Taking the window away mid-captcha loses whatever they had
/// typed and leaves the agent blocked on a wait nothing will end.
let refusal = claims =>
  `the browser is on screen for ${claims->Array.length->Int.toString} lane(s): ` ++
  claims->Array.join(", ") ++
  " -- somebody may be mid-handoff\n" ++
  "`passenger hide --force` takes it down anyway"

/// Take the browser off screen. Returns the exit status.
///
/// Without `--force` this releases only the human's own claim, and the window
/// goes away only if that was the last one -- exactly what `hideBrowser` does
/// for a lane. With it, every claim goes.
let hide = async (~force) => {
  let _ = await Lanes.sweep()
  let presenter = Present.select()
  dropStaleHumanClaim(presenter)
  let others = Lanes.screenClaims()->Array.filter(lane => lane != Lanes.human)

  if !force && others->Array.length > 0 {
    Console.error(refusal(others))
    1
  } else {
    // Asked *before* the dismissal, because afterwards every presenter answers
    // false and the two cases -- a window closed, and no window at all -- would
    // read identically. `passenger hide` on a machine with nothing on screen
    // said "dismissed", which is the report a person checks against when they
    // are wondering why they cannot see the browser.
    let wasShown = presenter.presented()
    let gone = force ? Lanes.releaseAllScreens() : Lanes.releaseScreen(Lanes.human)
    if gone {
      presenter.dismiss()
    }

    Console.log(
      switch (gone, presenter.observesPresence, wasShown) {
      | (false, _, _) =>
        `still shown: ${Lanes.screenClaims()->Array.length->Int.toString} other claim(s)`
      | (true, true, true) => "dismissed"
      | (true, true, false) => "nothing was on screen; no claims left either"
      // The `web` presenter hands out a URL and never learns whether anybody
      // opened it, so claiming either way would be an invention. Say what was
      // actually done -- the claims -- and who has to do the rest.
      | (true, false, _) => "claims released; close the viewer tab yourself, nothing here can"
      },
    )
    0
  }
}
