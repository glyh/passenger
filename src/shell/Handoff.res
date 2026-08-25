// Imperative shell: asking a human to solve what the agent must not.
//
// Nothing here tries to solve a challenge. Solver services get profiles burned
// and make the browser *more* detectable; a human solving it once into a
// persistent profile is both more robust and the defensible version of this.

open Models

/// How often a wait looks again. A `ref` only so the suite can assert what ends a
/// wait without sleeping out a five-minute budget -- the Python tests
/// monkeypatched the same number for the same reason. It is a clock, not a rule:
/// no behaviour here reads differently at a different interval.
let pollIntervalMs = ref(2000)

let now = () => Date.now()

/// One poll. False means the signature still matches, or mid-navigation.
let clear = async page =>
  switch await Probe.measure(page) {
  | probe => Detect.classify(probe)->Option.isNone
  // Navigating; try again next tick.
  | exception _ => false
  }

/// Poll until the vendor's signature stops matching, and say what ended it.
///
/// The other half of asking for a human. `waitForDismissal` waits on the human
/// saying they are done; this waits on the *page* saying the wall is gone, which
/// is a different fact and a stronger one -- a human can close the viewer without
/// having solved anything.
///
/// This is a measurement, not a judgement, and only because the signature table
/// is fixed (ticket 038): a vendor either serves that markup or does not. It used
/// to live inside `fetch`, re-extracting the page on every tick to hand the
/// content back in the same call. `fetch` is gone (ticket 046) and so is the
/// extraction -- what is polled now is the signature alone, and the caller reads
/// the page itself afterwards.
let waitUntilUnblocked = async (page, ~timeoutS=?) => {
  let budget = timeoutS->Option.getOr(Config.handoffTimeoutS.contents)
  let deadline = now() +. Int.toFloat(budget) *. 1000.0
  let answer = ref(None)
  while answer.contents->Option.isNone && now() < deadline {
    await Timers.sleep(pollIntervalMs.contents)
    if await clear(page) {
      let waited = budget - Float.toInt((deadline -. now()) /. 1000.0)
      answer := Some(`wall cleared after ${waited->Int.toString}s`)
    }
  }
  answer.contents->Option.getOr(`still blocked after ${budget->Int.toString}s`)
}

/// Block until the human closes the viewer, and say what ended the wait.
///
/// The deliberate half of asking for a human (ticket 018). Nothing here looks at
/// the page: with no signature to re-check there is no fact this side can read
/// that says "solved", and every proxy for one -- the URL changed, the word count
/// moved -- is the guess ticket 005 deleted, made again on weaker evidence. The
/// caller recognised the wall well enough to ask for a human; it can read the page
/// afterwards and see whether the wall is gone.
///
/// So the only thing waited on is the human saying they are done, which they say
/// by closing the window. A presenter that cannot see its own window is told to
/// poll instead of being handed a wait that would return instantly.
let waitForDismissal = async (presenter: Present.presenter, timeoutS) =>
  if !presenter.observesPresence {
    `cannot wait on the ${presenterToString(presenter.name)} presenter: it ` ++
    "cannot see whether the viewer is open. Poll the tab with `script` instead"
  } else {
    let deadline = now() +. Int.toFloat(timeoutS) *. 1000.0
    let answer = ref(None)
    while answer.contents->Option.isNone && now() < deadline {
      await Timers.sleep(pollIntervalMs.contents)
      if !presenter.presented() {
        let waited = timeoutS - Float.toInt((deadline -. now()) /. 1000.0)
        answer := Some(`viewer closed after ${waited->Int.toString}s`)
      }
    }
    answer.contents->Option.getOr(`still open after ${timeoutS->Int.toString}s`)
  }

let bringToFront = async page =>
  switch await Pw.bringToFront(page) {
  | () => ()
  // A tab that will not come forward is not a reason to fail the handoff: the
  // window is still going up, on some tab.
  | exception _ => ()
  }
