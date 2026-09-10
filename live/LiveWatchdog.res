// The idle reaper's lifecycle, against a real browser.
//
// Not a test, and could not be: every claim here is about a *second process*
// -- that `Browser.start` spawns one, that a second start does not spawn
// another, that it exits when Chrome goes, and that it stops the browser
// when the horizon passes. `Reaper.decide` is the part that needs no
// browser, and `test/Reaper_test.res` has it.
//
// `PASSENGER_IDLE_STOP=2` is what makes this run in seconds rather than
// hours. The setting is read through `Config`'s ref like every other, so the
// watchdog spawned below inherits this process's environment and reaps on a
// two-second horizon; the tick is a minute, so the reap lands on the first
// tick after it.
//
// Run it on a state dir of its own, or it stops the browser you are using:
//
//     PASSENGER_STATE=/tmp/passenger-live PASSENGER_PORT=9333 \
//       node live/LiveWatchdog.res.mjs

@val @scope("process") external env: Dict.t<string> = "env"

let tickS = 70

let say = line => Console.log(line)

let main = async () => {
  env->Dict.set("PASSENGER_IDLE_STOP", "2")
  Config.idleStopS := 2

  say(`start: ${await Browser.start()}`)
  let first = NestedSessions.watchdogPid()
  say(`watchdog: ${first->Option.mapOr("none", p => p->Int.toString)}`)

  // Twice, because "already running" summons too -- a browser left behind by
  // a previous client still deserves a reaper -- and must not stack a second
  // one beside the live watcher.
  say(`start again: ${await Browser.start()}`)
  let second = NestedSessions.watchdogPid()
  say(
    second->Option.getOr(0) == first->Option.getOr(-1)
      ? "single-instance: ok, the same pid"
      : `single-instance: FAILED, ${second->Option.mapOr("none", p => p->Int.toString)} is not the first`,
  )

  // Nobody has called anything since the start, so the horizon has already
  // passed by the time the first tick lands.
  say(`waiting ${tickS->Int.toString}s for a tick...`)
  await Timers.sleep(tickS * 1000)

  say(`browser up: ${(await Browser.isUp()) ? "still up -- FAILED" : "stopped, as it should be"}`)
  say(`watchdog pid file: ${NestedSessions.watchdogPid()->Option.mapOr("cleared", p => p->Int.toString)}`)
  say(`note: ${Reaper.peekNote()->Option.getOr("none -- FAILED")}`)
  Reaper.forgetNote()
}

main()->Promise.ignore
