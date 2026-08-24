// Waiting on a human, and the one presenter that cannot be waited on.
//
// The scar is a design one, caught while building ticket 018 rather than in
// production: `Presented()` is a real observation only for the local presenter.
// LinkPresenter and NullPresenter answer false unconditionally, because whether
// anyone opened a URL handed to them is unknowable from here -- so a wait built
// on "the viewer closed" would report success the instant it began, on exactly
// the deployments that most need a human. The refusal is the fix, and this is
// what stops it being quietly removed as a redundant branch.

using Passenger;
using Xunit;

namespace Passenger.Tests;

[Collection(nameof(SharedStateCollection))]
public class HandoffTests : IDisposable
{
    private readonly int restore = Handoff.PollIntervalMs;

    public HandoffTests() => Handoff.PollIntervalMs = 10;

    public void Dispose()
    {
        Handoff.PollIntervalMs = restore;
        GC.SuppressFinalize(this);
    }

    [Fact]
    public async Task APresenterThatCannotSeeItsWindowRefusesTheWait()
    {
        var presenter = new FakePresenter(PresenterName.Web, observes: false);
        string answer = await Handoff.WaitForDismissalAsync(presenter, timeoutS: 300);
        Assert.Contains("cannot wait", answer, StringComparison.Ordinal);
        Assert.Contains("web", answer, StringComparison.Ordinal);
        // And it refused instantly rather than sleeping out the budget.
        Assert.Equal(0, presenter.Polls);
    }

    [Fact]
    public async Task TheWaitEndsWhenTheHumanClosesTheViewer()
    {
        var presenter = new FakePresenter(PresenterName.Local, observes: true,
                                          closesAfter: 3);
        Assert.Contains("viewer closed",
            await Handoff.WaitForDismissalAsync(presenter, timeoutS: 5),
            StringComparison.Ordinal);
    }

    [Fact]
    public async Task AViewerLeftOpenTimesOutWithoutClaimingOtherwise()
    {
        var presenter = new FakePresenter(PresenterName.Local, observes: true);
        Assert.StartsWith("still open",
            await Handoff.WaitForDismissalAsync(presenter, timeoutS: 1),
            StringComparison.Ordinal);
    }

    /// <summary>A presenter whose window state is whatever the test says it is.</summary>
    private sealed class FakePresenter(PresenterName name, bool observes,
                                       int? closesAfter = null) : IPresenter
    {
        public int Polls { get; private set; }

        public PresenterName Name => name;

        public bool ObservesPresence => observes;

        public bool Available() => true;

        public Task<string> PresentAsync() => Task.FromResult("presented");

        public void Dismiss()
        {
        }

        public bool Presented()
        {
            Polls++;
            return closesAfter is null || Polls < closesAfter;
        }
    }
}
