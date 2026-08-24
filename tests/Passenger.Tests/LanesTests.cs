// The lane registry, without a browser.
//
// Everything here is the table and its rules; nothing opens Chrome. What is left
// untested by that boundary is named at the bottom of ticket 040 -- adoption
// against a real popup, the screen refcount across two live processes, and
// expiry actually closing tabs.
//
// `Sandbox` points the state directory at a temp path before any test runs, so
// `Lanes.DbFile` is already inside it: these tests never touch a developer's
// real registry.
//
// Not parallelised, and that is not a workaround. Every test here writes one
// sqlite file and starts by dropping its tables, so two running at once would
// each be resetting the other's fixture. The Python suite got this for free by
// being single-threaded; xUnit runs classes in parallel by default.

using Passenger;
using Xunit;

namespace Passenger.Tests;

[Collection(nameof(SharedStateCollection))]
public class LanesTests : IDisposable
{
    private readonly FakeChrome chrome = new(["T1", "T2", "T3"]);

    public LanesTests()
    {
        // Each test starts on an empty table, since the file is shared.
        Lanes.Reset();
        Lanes.Chrome = chrome;
    }

    public void Dispose()
    {
        Lanes.Chrome = new LiveChromeTabs();
        GC.SuppressFinalize(this);
    }

    private static long Now() => DateTimeOffset.UtcNow.ToUnixTimeSeconds();

    [Fact]
    public void OpenLaneMintsDistinctIds() =>
        Assert.NotEqual(Lanes.OpenLane(), Lanes.OpenLane());

    [Fact]
    public void ReservedLanesExistWithoutBeingOpened()
    {
        Assert.Equal(Lanes.DefaultTtlS, Lanes.Require(Lanes.Cli).TtlS);
        // `orphan` never expires: a TTL there would collect the tabs a human
        // opened during a handoff, which is what ticket 018 exists to prevent.
        Assert.Equal(Lanes.NoTtl, Lanes.Require(Lanes.Orphan).TtlS);
    }

    [Fact]
    public void UnknownLaneIsRefused() =>
        Assert.Throws<LaneNotFoundException>(() => Lanes.Require("nobody"));

    [Fact]
    public void ATabBelongsToExactlyOneLane()
    {
        string first = Lanes.OpenLane(), second = Lanes.OpenLane();
        Lanes.Adopt("T1", first);
        Assert.Equal(["T1"], Lanes.TabsOf(first));
        Assert.Empty(Lanes.TabsOf(second));
        Lanes.Adopt("T1", second);
        Assert.Empty(Lanes.TabsOf(first));
        Assert.Equal(["T1"], Lanes.TabsOf(second));
    }

    [Fact]
    public void ExpiryNeedsQuietNotMerelyAge()
    {
        // The bug this guards: a lane collected while its call was still
        // running. A `script` with a 600s budget outlives a 30-minute lane only
        // if nothing restarts the clock, so every call touches the lane on entry
        // and on return.
        string lane = Lanes.OpenLane(ttlS: 60);
        Assert.Equal([lane], Lanes.Expired(Now() + 61));
        Lanes.Touch(lane);
        // The clock now runs from the touch, not from when the lane was opened.
        Assert.Empty(Lanes.Expired(Now() + 59));
    }

    [Fact]
    public void ALaneWithNoTtlNeverExpires()
    {
        string lane = Lanes.OpenLane(ttlS: Lanes.NoTtl);
        Assert.DoesNotContain(lane, Lanes.Expired(Now() + 10_000));
    }

    [Fact]
    public void SetTtlRestartsTheClock()
    {
        string lane = Lanes.OpenLane(ttlS: 60);
        Lanes.SetTtl(lane, 7200);
        Assert.Equal(7200, Lanes.Require(lane).TtlS);
        Assert.Empty(Lanes.Expired(Now() + 61));
    }

    [Fact]
    public void DestroyingALaneTakesItsRowsWithIt()
    {
        string lane = Lanes.OpenLane();
        Lanes.Adopt("T1", lane);
        Lanes.ClaimScreen(lane);
        Lanes.Destroy(lane);
        Assert.Throws<LaneNotFoundException>(() => Lanes.Require(lane));
        Assert.Null(Lanes.Owner("T1"));
        Assert.Empty(Lanes.ScreenClaims());
    }

    [Fact]
    public void ReservedLanesAreEmptiedRatherThanRemoved()
    {
        // `destroyLane('orphan')` reading as success while the lane comes
        // straight back on the next call would be a lie.
        Lanes.Adopt("T1", Lanes.Orphan);
        Lanes.Destroy(Lanes.Orphan);
        Assert.Empty(Lanes.TabsOf(Lanes.Orphan));
        Assert.Equal(Lanes.Orphan, Lanes.Require(Lanes.Orphan).Id);
    }

    // --- reconciling -------------------------------------------------------

    [Fact]
    public void ATabChromeNoLongerHoldsIsForgotten()
    {
        string lane = Lanes.OpenLane();
        Lanes.Adopt("GONE", lane);
        Lanes.Reconcile([], new Dictionary<string, string>());
        Assert.Empty(Lanes.TabsOf(lane));
    }

    [Fact]
    public void APopupJoinsTheLaneThatOpenedIt()
    {
        // window.open and target=_blank, which would otherwise leak. Such a
        // target has no row, so no lane can see it, no lane can close it, and
        // the sweep never reaches it -- the sweep collects lanes, not tabs.
        string lane = Lanes.OpenLane();
        Lanes.Adopt("PARENT", lane);
        Lanes.Reconcile(["PARENT", "POPUP"],
                        new Dictionary<string, string> { ["POPUP"] = "PARENT" });
        Assert.Equal(lane, Lanes.Owner("POPUP"));
    }

    [Fact]
    public void ATabWithNoOpenerLandsInOrphan()
    {
        // A human opening tabs during a handoff. Chrome records no opener for
        // them, so there is nothing to trace and guessing would be a heuristic.
        Lanes.Reconcile(["HUMAN"], new Dictionary<string, string>());
        Assert.Equal(Lanes.Orphan, Lanes.Owner("HUMAN"));
    }

    [Fact]
    public void APopupWhoseOpenerIsUnknownLandsInOrphan()
    {
        Lanes.Reconcile(["POPUP"],
                        new Dictionary<string, string> { ["POPUP"] = "VANISHED" });
        Assert.Equal(Lanes.Orphan, Lanes.Owner("POPUP"));
    }

    [Fact]
    public void ReconcileLeavesSettledTabsWhereTheyAre()
    {
        string lane = Lanes.OpenLane();
        Lanes.Adopt("T1", lane);
        Lanes.Reconcile(["T1"],
                        new Dictionary<string, string> { ["T1"] = "SOMETHING" });
        Assert.Equal(lane, Lanes.Owner("T1"));
    }

    // --- the screen --------------------------------------------------------

    [Fact]
    public void TheScreenStaysUpWhileAnotherLaneHoldsIt()
    {
        // The interference this replaces: lane A summons a human for a captcha,
        // lane B finishes something unrelated and calls hideBrowser, and the
        // window disappears mid-solve.
        string first = Lanes.OpenLane(), second = Lanes.OpenLane();
        Lanes.ClaimScreen(first);
        Lanes.ClaimScreen(second);
        Assert.False(Lanes.ReleaseScreen(second));
        Assert.True(Lanes.ReleaseScreen(first));
    }

    [Fact]
    public void ReleasingAClaimNobodyHoldsIsNotAnError() =>
        Assert.True(Lanes.ReleaseScreen(Lanes.OpenLane()));

    [Fact]
    public void ClaimingTwiceStillNeedsOneRelease()
    {
        string lane = Lanes.OpenLane();
        Lanes.ClaimScreen(lane);
        Lanes.ClaimScreen(lane);
        Assert.True(Lanes.ReleaseScreen(lane));
    }

    // --- closing ------------------------------------------------------------

    [Fact]
    public void ClosingReachesOnlyThisLanesTabs()
    {
        string mine = Lanes.OpenLane(), theirs = Lanes.OpenLane();
        Lanes.Adopt("T1", mine);
        Lanes.Adopt("T2", theirs);
        Assert.Equal(1, Lanes.CloseTabs(mine, ["T1", "T2"]));
        Assert.Equal(["T1"], chrome.Closed);
        Assert.Equal(["T2"], Lanes.TabsOf(theirs));
    }

    [Fact]
    public void TheLastTabInTheBrowserIsNeverClosed()
    {
        // Chrome exits when it loses its final tab, taking the daemon and the
        // warm session with it.
        //
        // The old `close_other_tabs` kept one back by being phrased as "keep
        // that one". Under lanes the survivor must belong to nobody in
        // particular, so the rule lives here instead, on the one path every
        // close goes through.
        chrome.Ids = ["ONLY"];
        string lane = Lanes.OpenLane();
        Lanes.Adopt("ONLY", lane);
        Assert.Equal(0, Lanes.CloseTabs(lane, ["ONLY"]));
        Assert.Empty(chrome.Closed);
    }

    [Fact]
    public void ASweepCollectsAnExpiredLaneAndItsTabs()
    {
        string stale = Lanes.OpenLane(ttlS: 1);
        Lanes.Adopt("T1", stale);
        Lanes.Adopt("T2", Lanes.Orphan);
        Lanes.Adopt("T3", Lanes.Orphan);
        Thread.Sleep(1100);
        Assert.Equal([stale], Lanes.Sweep());
        Assert.Equal(["T1"], chrome.Closed);
        Assert.Throws<LaneNotFoundException>(() => Lanes.Require(stale));
    }

    [Fact]
    public void ASweepLeavesOrphanAloneHoweverOld()
    {
        // A TTL on `orphan` would collect the tabs a human opened during a
        // handoff, which is the one thing ticket 018 exists to prevent.
        Lanes.Adopt("T1", Lanes.Orphan);
        Thread.Sleep(1100);
        Assert.Empty(Lanes.Sweep());
        Assert.Empty(chrome.Closed);
    }

    [Fact]
    public void AnExpiredLaneIsRefusedRatherThanFailingOnADanglingRow()
    {
        // The order bug: `Require` before `Sweep`.
        //
        // A lane that expired between calls is still a row, so checking first
        // let it through; the sweep then destroyed it underneath the call and
        // the first `Adopt` hit a foreign key with nothing behind it -- a sqlite
        // constraint failure reaching the caller instead of LANE_NOT_FOUND.
        // Sweeping first makes the refusal the one the caller can act on.
        string lane = Lanes.OpenLane(ttlS: 1);
        Thread.Sleep(1100);
        Lanes.Sweep();
        Assert.Throws<LaneNotFoundException>(() => Lanes.Require(lane));
    }

    [Fact]
    public void CountsRevealTabsPilingUpInALaneNobodyIsWatching()
    {
        // The one number that reveals a lane you do not own -- a count, never a
        // listing, because a lane's tabs are nobody else's business.
        Lanes.Adopt("T1", Lanes.OpenLane());
        Lanes.Adopt("T2", Lanes.Orphan);
        (int open, int orphaned) = Lanes.Counts();
        Assert.Equal(3, open);
        Assert.Equal(1, orphaned);
    }

    /// <summary>Chrome's target list, without Chrome. Records what was closed.</summary>
    private sealed class FakeChrome(IEnumerable<string> ids) : IChromeTabs
    {
        public List<string> Ids { get; set; } = [.. ids];

        public List<string> Closed { get; } = [];

        public IReadOnlyList<string> LiveTabs() => Ids;

        public bool Close(string tab)
        {
            Closed.Add(tab);
            Ids.Remove(tab);
            return true;
        }

        public IReadOnlyDictionary<string, string> Openers() =>
            new Dictionary<string, string>();
    }
}

/// <summary>
/// Everything that writes the one sqlite file or the one settings object, run in
/// sequence rather than in parallel.
/// </summary>
[CollectionDefinition(nameof(SharedStateCollection), DisableParallelization = true)]
public class SharedStateCollection;
