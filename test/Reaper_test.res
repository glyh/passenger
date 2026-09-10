// The reaping decision, without a browser and without a clock.
//
// The whole point of `Reaper.decide` being a function of its arguments is
// that the horizon can be crossed here in one line instead of in three
// hours. Nothing in this file spawns anything: the watchdog's lifecycle --
// that it is spawned once, that it exits when Chrome goes, that it pings
// before it tears down -- needs a real browser and lives in
// `live/LiveWatchdog.res`.
//
// New with ticket 077; there is no C# oracle for any of it.

let idle = 100
let blind = Int.toFloat(idle * Reaper.blindMultiple)

// Facts that say "reap it": nothing on screen, no lane holding a tab, and
// the last touch older than the horizon. Each case moves one of them.
let at = (
  ~now=1000.0,
  ~newest=1000.0 -. Int.toFloat(idle),
  ~idleStopS=idle,
  ~claims=[],
  ~occupied=Reaper.Known([]),
  ~blindSince=None,
  (),
) => Reaper.decide(~now, ~newest, ~idleStopS, ~claims, ~occupied, ~blindSince)

T.test("fires when the horizon has passed and nothing is held", () =>
  T.equal(at(), Reaper.Fire)
)

T.test("waits a second short of the horizon", () =>
  T.equal(at(~newest=1000.0 -. Int.toFloat(idle) +. 1.0, ()), Reaper.Wait)
)

T.test("a screen claim holds the reap off", () => T.equal(at(~claims=["human"], ()), Reaper.Wait))

T.test("a lane with a live tab holds the reap off", () =>
  T.equal(at(~occupied=Reaper.Known([("L1", 1)]), ()), Reaper.Wait)
)

T.test("zero means never, however long it has been idle", () =>
  T.equal(at(~idleStopS=0, ~newest=0.0, ()), Reaper.Wait)
)

// The blind path. Chrome answering nothing is the wedge `stop` exists for,
// and the sighted reap can never fire on it -- so silence itself is the
// evidence, at eight times the horizon.
T.test("silence alone does not fire, however idle", () =>
  T.equal(at(~occupied=Reaper.Unknown, ~newest=0.0, ()), Reaper.Wait)
)

T.test("silence for the blind horizon fires blind", () =>
  T.equal(
    at(~occupied=Reaper.Unknown, ~newest=1000.0 -. blind, ~blindSince=Some(1000.0 -. blind), ()),
    Reaper.FireBlind,
  )
)

T.test("a retry against a wedged browser is use, and holds the blind reap off", () =>
  T.equal(
    at(~occupied=Reaper.Unknown, ~newest=999.0, ~blindSince=Some(1000.0 -. blind), ()),
    Reaper.Wait,
  )
)

T.test("silence shorter than the blind horizon is a stall, not a wedge", () =>
  T.equal(
    at(~occupied=Reaper.Unknown, ~newest=0.0, ~blindSince=Some(999.0), ()),
    Reaper.Wait,
  )
)

T.test("a claim stops even the blind reap", () =>
  T.equal(
    at(
      ~occupied=Reaper.Unknown,
      ~newest=0.0,
      ~blindSince=Some(0.0),
      ~claims=["human"],
      (),
    ),
    Reaper.Wait,
  )
)

// The silence clock itself: started by the first unanswered round, held
// across the ones after it, and cleared the moment Chrome speaks again.
T.test("the first unanswered round starts the silence clock", () =>
  T.equal(Reaper.nextBlindSince(~occupied=Reaper.Unknown, ~current=None, ~now=50.0), Some(50.0))
)

T.test("later unanswered rounds keep the first one's timestamp", () =>
  T.equal(
    Reaper.nextBlindSince(~occupied=Reaper.Unknown, ~current=Some(50.0), ~now=900.0),
    Some(50.0),
  )
)

T.test("one answer clears the silence clock", () =>
  T.equal(Reaper.nextBlindSince(~occupied=Reaper.Known([]), ~current=Some(50.0), ~now=900.0), None)
)
