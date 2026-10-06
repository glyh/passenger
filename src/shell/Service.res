// The one orchestration, and now the only frontend's whole middle.
//
// A blocked page is an *outcome*, not an error: it is the expected,
// designed-for result of pointing this tool at a protected site. So it comes
// back as a value in a union rather than as a raised exception, and the door
// decides what to do with it.
//
// The C# side spelled these unions as a base record with a `type` discriminator
// and wrote out every JSON property name, because C# has no unions and its
// serialiser had to be told the wire shape. Here the unions are unions and the
// wire shape is written once, in `encode` -- which is the same amount of
// writing, in one place instead of scattered over attributes, and still the
// same bytes: pydantic serialised this shape on the Python side and nothing
// downstream has been asked to change since.

open Models

/// What a page holds now: a wall, or the fact that nobody looked.
///
/// It carried a third member, `Measured`, until ticket 048: a character count,
/// a title, a url and the picture geometry, taken on every reply whether or not
/// the caller wanted them. The measuring moved to the caller, which is where
/// reading a page already went with ticket 047.
///
/// `Unchecked` is a member rather than a null `page`, for ticket 042's reason: a
/// negative nobody tested must not arrive looking like one that was. With
/// `Measured` deleted the slot would otherwise carry a wall or nothing, and
/// *nothing* would mean both "checked, and clean" and "did not check" -- the
/// shape 042 removed from the attach message, where a check that never ran read
/// as a page that was fine.
type pageOutcome =
  | Unchecked
  /// A signature matched, so a human is genuinely required.
  ///
  /// `evidence` and `proposed_condition` used to ride along: a page that merely
  /// yielded few words was screenshotted and turned into a candidate rule. That
  /// path is gone with the word-count tier (ticket 005) -- it was proposing to
  /// block whole domains by their own name.
  ///
  /// No `tab` on this one: it carried one from ticket 018, because an agent that
  /// wanted to summon a human deliberately was otherwise reading `listTabs` and
  /// matching on a URL. Flattening put the tab at the top of every reply, so the
  /// copy inside here would be the same string twice.
  | Blocked({name: string, kind: kind, url: string, hint: string})

type scriptOutcome =
  /// A script that finished, and what the tab looked like afterwards.
  | Ran({tab: string, returned: JSON.t, page: option<pageOutcome>})
  /// A script that did not finish -- bad source, a throw, or a handle.
  ///
  /// An outcome rather than an exception, for the same reason `blocked` is one:
  /// the caller's next move is to fix the script and call again, and it needs
  /// the line number and the state of the tab to do that. The tab is left
  /// exactly where the script left it.
  | Failed({tab: string, code: Errors.code, error: string, where: string, page: option<pageOutcome>})

let str = JSON.Encode.string

/// The reply, flat.
///
/// This was two nested tagged unions until the shape was flattened: a `type` of
/// `ran` or `failed` at the top, and a `page` slot holding a second record whose
/// own `type` was `blocked` or `unchecked`. Both discriminators were pydantic's,
/// carried through the C# port because a serialiser there needed to be told how
/// to spell a union it had no way to express -- and neither is worth a level of
/// nesting to a caller whose language tests a field by asking whether it is
/// there. `if (r.blocked)` is the whole of it now.
///
/// The union survives on *this* side, where it earns its keep: `encode` is a
/// `switch` the compiler checks, so a member added later cannot quietly fail to
/// reach the wire.
///
/// What a caller reads:
///
///     tab           always -- the tab this ran on, and the handle to continue
///     returned      on success. absent when the script did not finish
///     code/error/   on failure, and their presence *is* the failure. absent on
///       where       success, so `if (r.error)` is the test
///     wallChecked   always. false is `checkWall: false`, and it is a fact about
///                   what this side did rather than about the page (ticket 042):
///                   a check that never ran must not read as a page that was fine
///     blocked       only when a vendor's markup matched, so `if (r.blocked)`
///
/// `blocked` no longer repeats the tab it is on. It carried one because the
/// nested record had no other way to name it (ticket 018), and flat it is
/// already there.
let blockedField = page =>
  switch page {
  | Some(Blocked({name, kind, url, hint})) =>
    [
      (
        "blocked",
        JSON.Encode.object(
          Dict.fromArray([
            ("name", str(name)),
            ("kind", str(kindToString(kind))),
            ("url", str(url)),
            ("hint", str(hint)),
          ]),
        ),
      ),
    ]
  | _ => []
  }

let wallChecked = page =>
  switch page {
  | Some(Unchecked) => false
  | _ => true
  }

let encode = outcome => {
  let common = switch outcome {
  | Ran({tab, returned, page}) =>
    [("tab", str(tab)), ("returned", returned)]
    ->Array.concat([("wallChecked", JSON.Encode.bool(wallChecked(page)))])
    ->Array.concat(blockedField(page))
  | Failed({tab, code, error, where, page}) =>
    [
      ("tab", str(tab)),
      ("code", str(Errors.codeToString(code))),
      ("error", str(error)),
      ("where", str(where)),
      ("wallChecked", JSON.Encode.bool(wallChecked(page))),
    ]->Array.concat(blockedField(page))
  }
  JSON.Encode.object(Dict.fromArray(common))
}

/// Is a known vendor's wall on this page?
///
/// The tail every read shares. It used to extract the page as well and hand both
/// back; extraction left with `fetch` (ticket 046) and what remains is the one
/// judgement this side is still allowed to make -- a match against a fixed table
/// of vendors' own markup, which is a measurement because a vendor either serves
/// that markup or does not (ticket 038).
let inspect = async page => Detect.classify(await Probe.measure(page))

let blockedHint =
  "showBrowser with this tab and a wait; solve it, then call again " ++
  "with this same tab -- it is still open, and still there"

/// What the tab holds now: a wall, or nothing this side went looking for.
///
/// Taken unless the caller says otherwise, where ticket 047 had made it
/// unconditional. 047 deleted a `readPage` switch on the reasoning that nobody
/// needs to opt out of something cheap, and that was right about what the reply
/// carried *then* -- a character count and a picture geometry, neither of which
/// the caller could refuse. Ticket 048 deleted those, which leaves the wall
/// probe as the only work here nobody asked for: two round trips, a title and a
/// selector match, on every call. A caller driving one page across many calls
/// pays them every time, and that caller is the one `checkWall` is for.
let look = async (page, checkWall) =>
  if !checkWall {
    Some(Unchecked)
  } else {
    switch await inspect(page) {
    | None => None
    | Some(blocker) =>
      Some(
        Blocked({
          name: blocker.signature.name,
          kind: blocker.signature.kind,
          url: blocker.probe.url,
          hint: blockedHint,
        }),
      )
    }
  }

/// `undefined` is what a script with no `return` leaves behind, and it is not a
/// JSON value. It crosses as null, which is what "said nothing" means on the
/// wire -- and what the C# door's `object?` already did.
let returnedOrNull: 'a => JSON.t = %raw(`v => (v === undefined ? null : v)`)

/// The passthrough door: caller-supplied code, run against a page.
///
/// Everything this project knows how to do to a page is reachable from here
/// without being rewrapped, because what is handed over is `Page` itself (ticket
/// 004). What this function adds is the envelope: which tab, a bounded clock,
/// and a reading of the ending page -- so a challenge met halfway through a
/// sequence comes back as `blocked`, not as a puzzling empty string.
let run = async (~source, ~lane, ~tab as named=?, ~operationTimeoutS=?, ~checkWall=true) => {

  let _ = await Lanes.sweep()
  Lanes.require(lane)->ignore
  Lanes.touch(lane)

  // Everything below detaches on the way out, including the ways out that
  // throw -- `pageFor` refusing a tab this lane does not own is the common one.
  await Session.use(async session => {
  let page = await Session.pageFor(session, lane, named)
  // The tab this call drives goes to the front, and that is what keeps it
  // running: Chrome does not throttle the active tab of a window, it throttles
  // every other one.
  //
  // This replaces the hidden launch's three anti-throttling flags (ticket 088).
  // They held *every* tab at full rate, which ticket 078 measured at 31x the
  // timer rate and ~0.67 core for six tabs nobody was using, and only
  // `--disable-background-timer-throttling` was doing anything at all -- the two
  // occlusion flags are inert under headless sway, which never reports the
  // window as occluded. They were also a fingerprint: a page can read its own
  // `document.visibilityState` and its own tick rate, and a *hidden* tab ticking
  // at a visible tab's rate is not something a human's browser does. Measured
  // after this change's premise, on the same rig: activating a background tab
  // takes it from 0.57/s to 20.00/s and pushes the previous front tab down to
  // 0.93/s, reversibly.
  //
  // A failure here is not fatal -- the page is still driveable, just slower if
  // something else holds the front -- so it is not worth ending a call over.
  switch await page->Pw.bringToFront {
  | () => ()
  | exception _ => ()
  }
  // Every Playwright call inside the script inherits this, so a wait on a
  // selector that never appears ends the call instead of the session. A script
  // that loops without calling Playwright is not interruptible; that is the
  // honest limit of running code in-process.
  //
  // Only when asked, since ticket 074. It defaulted to 60s and was clamped to
  // 1..600 -- a bound inherited from pydantic's `Field(ge=1)` and never
  // revisited -- and both were doing less than the name suggested. This is a
  // budget for one *operation*, not for the script: ten clicks at 60 is ten
  // minutes, and a `while(true)` is forever either way. So there was nothing to
  // be gained by capping it at ten minutes on a machine that is the caller's
  // own, and untouched it means Playwright's own default rather than this
  // side's guess. Zero is Playwright's spelling of no limit, and reaches it.
  switch operationTimeoutS {
  | Some(seconds) => page->Pw.setDefaultTimeout(seconds * 1000)
  | None => ()
  }
  let tab = await Session.targetId(session, page)

  let outcome = switch await Script.execute(source, page) {
  | returned =>
    Ran({tab, returned: returnedOrNull(returned), page: await look(page, checkWall)})
  | exception Errors.Passenger({code, message, detail}) =>
    Failed({
      tab,
      code,
      error: message,
      where: detail->Option.getOr(""),
      page: await look(page, checkWall),
    })
  // Insurance, and it is worth saying that no probe could trigger it: nine
  // adversarial scripts -- closing their own tab, killing the context, throwing
  // a number, rejecting a bare string, a Playwright timeout, an unreachable URL
  // -- all arrive above, because `Script.execute` wraps what the caller's code
  // throws. What is left uncovered is this module's own Playwright calls, which
  // could fail if a tab dies between `pageFor` and here. Cheap to catch, and the
  // alternative is a caller losing a tab id to an MCP internal error.
  | exception JsExn(e) =>
    Failed({
      tab,
      code: ScriptRaised,
      error: Script.described(e),
      where: "",
      page: await look(page, checkWall),
    })
  }

  // A script may have opened tabs of its own -- window.open, or a link with
  // target="_blank". Attributing them to the lane that caused them is what keeps
  // them from becoming invisible and uncollectable.
  let open_ = await Promise.all(
    session.context->Pw.pages->Array.map(p => Session.targetId(session, p)),
  )

  Lanes.reconcile(open_, await Targets.openers())
  Lanes.touch(lane)
  outcome
  })
}
