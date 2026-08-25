// Waiting on a human, and the one presenter that cannot be waited on.
//
// The oracle is `tests/Passenger.Tests/HandoffTests.cs`, all three cases. The
// scar is a design one, caught while building ticket 018 rather than in
// production: `presented` is a real observation only for the local presenter.
// The link and null presenters answer false unconditionally, because whether
// anyone opened a URL handed to them is unknowable from here -- so a wait built
// on "the viewer closed" would report success the instant it began, on exactly
// the deployments that most need a human. The refusal is the fix, and this is
// what stops it being quietly removed as a redundant branch.

Handoff.pollIntervalMs := 10

/// A presenter whose window state is whatever the test says it is.
let fake = (name, ~observes, ~closesAfter=?) => {
  let polls = ref(0)
  let presenter: Present.presenter = {
    name,
    observesPresence: observes,
    available: () => true,
    present: async () => "presented",
    dismiss: () => (),
    presented: () => {
      polls := polls.contents + 1
      switch closesAfter {
      | None => true
      | Some(n) => polls.contents < n
      }
    },
  }
  (presenter, polls)
}

T.testAsync("a presenter that cannot see its window refuses the wait", async () => {
  let (presenter, polls) = fake(Web, ~observes=false)
  let answer = await Handoff.waitForDismissal(presenter, 300)
  T.ok(answer->String.includes("cannot wait"))
  T.ok(answer->String.includes("web"))
  // And it refused instantly rather than sleeping out the budget.
  T.equal(polls.contents, 0)
})

T.testAsync("the wait ends when the human closes the viewer", async () => {
  let (presenter, _) = fake(Local, ~observes=true, ~closesAfter=3)
  T.ok((await Handoff.waitForDismissal(presenter, 5))->String.includes("viewer closed"))
})

T.testAsync("a viewer left open times out without claiming otherwise", async () => {
  let (presenter, _) = fake(Local, ~observes=true)
  T.ok((await Handoff.waitForDismissal(presenter, 1))->String.startsWith("still open"))
})
