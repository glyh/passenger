// Waiting for something to become true, and searching a list with an async test.
//
// Both existed seven times over as a `for` loop guarding its whole body on a
// `found` flag -- which is what a `for` with a `break` becomes when the language
// has no `break`. They kept iterating after the answer arrived, doing nothing,
// and one of them (`Handoff`) had been written as a `while` instead, so the same
// act had two spellings in one codebase.
//
// Recursion says it once. Nothing here is clever: these are the two shapes the
// shell actually needed, and they stop when they are done.

/// Run `check` until it answers true, or the budget runs out. True if it did.
///
/// The delay comes *after* a failed check, never before the first one, so
/// something already true costs no wait at all.
let rec until = async (~times, ~everyMs, check) =>
  if times <= 0 {
    false
  } else if await check() {
    true
  } else {
    await Timers.sleep(everyMs)
    await until(~times=times - 1, ~everyMs, check)
  }

/// The first item a predicate accepts. `Array.find`, for a predicate that has to
/// await -- which the stdlib's cannot take.
let rec find = async (items, predicate, ~from=0) =>
  switch items->Array.get(from) {
  | None => None
  | Some(item) =>
    if await predicate(item) {
      Some(item)
    } else {
      await find(items, predicate, ~from=from + 1)
    }
  }
