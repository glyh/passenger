// Parsing Chrome's target list. Pure: a recorded payload, no browser.

using System.Text.Json.Nodes;
using Passenger;
using Xunit;

namespace Passenger.Tests;

public class TargetsTests
{
    // Recorded from the live endpoint while a tab sat stuck mid-navigation
    // (ticket 012). Note the stuck tab: its title is still the document it had
    // before the navigation started, which is why the title cannot be used to
    // tell a stuck tab from a healthy one -- only asking its renderer can.
    private const string Listing = """
        [
          {"description": "", "devtoolsFrontendUrl": "/devtools/inspector.html?ws=x",
           "id": "35220A8B", "title": "about:blank", "type": "page",
           "url": "http://10.255.255.1:81/hang",
           "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/35220A8B"},
          {"description": "", "id": "C3E56F6E", "title": "Example Domain",
           "type": "page", "url": "https://example.com/",
           "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/C3E56F6E"},
          {"description": "", "id": "867A5141", "title": "Omnibox Popup",
           "type": "browser_ui", "url": "chrome://omnibox-popup.top-chrome/",
           "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/867A5141"}
        ]
        """;

    [Fact]
    public void EveryTargetIsParsedWithItsSocket()
    {
        IReadOnlyList<Target> targets = Targets.Parse(Listing);
        Assert.Equal(3, targets.Count);
        Assert.EndsWith("/35220A8B", targets[0].WebsocketUrl, StringComparison.Ordinal);
    }

    [Fact]
    public void ChromesOwnUiIsNotAPage()
    {
        // Chrome lists its omnibox popup as a target. Stopping *its* navigation
        // would be meaningless, and it is not a tab anyone opened.
        Assert.Equal(["35220A8B", "C3E56F6E"],
            Targets.Parse(Listing).Where(t => t.IsPage).Select(t => t.Id));
    }

    [Fact]
    public void AStuckTabLooksOrdinaryFromTheOutside()
    {
        // Ticket 012: the stuck tab still reports the title of the document it
        // had before the navigation began, and a healthy tab with no <title>
        // reports its URL. Nothing in this payload separates them, which is why
        // Unstick asks the renderer instead of reading fields.
        IReadOnlyList<Target> targets = Targets.Parse(Listing);
        Assert.NotEmpty(targets[0].Title);
        Assert.NotEmpty(targets[1].Title);
    }

    // --- What one `Page.getFrameTree` answer says about a tab (ticket 042).
    //
    // Recorded from the live endpoint against a socket that accepts and then
    // answers nothing. Two tabs pointed at it, and they answer *differently*:
    // the one that already had a document goes silent, the one created at the
    // URL answers at once and says it has no document.

    private static readonly JsonNode? Silent = null;  // never answered at all

    private static JsonNode Uncommitted => JsonNode.Parse("""
        {"id": 1, "result": {"frameTree": {"frame": {
            "id": "9D5703E5", "loaderId": "A1", "url": "",
            "securityOrigin": "://", "mimeType": ""}}}}
        """)!;

    private static JsonNode Healthy => JsonNode.Parse("""
        {"id": 1, "result": {"frameTree": {"frame": {
            "id": "9D5703E5", "loaderId": "A1", "url": "https://example.com/",
            "securityOrigin": "https://example.com", "mimeType": "text/html"}}}}
        """)!;

    private static JsonNode Blank => JsonNode.Parse("""
        {"id": 1, "result": {"frameTree": {"frame": {
            "id": "9D5703E5", "loaderId": "A1", "url": "about:blank",
            "securityOrigin": "://", "mimeType": "text/html"}}}}
        """)!;

    private static JsonNode Refused => JsonNode.Parse("""
        {"id": 1, "error": {"code": -32000, "message": "Not attached"}}
        """)!;

    [Fact]
    public void ARendererThatNeverAnswersIsTheWedge012Knew() =>
        Assert.Equal(Wedge.Silent, Targets.Verdict(Silent));

    [Fact]
    public void ATabWithNoDocumentIsWedgedEvenThoughItAnswered()
    {
        // Ticket 042: the tab reads as healthy by every other measure -- it
        // answers in under 10ms -- and it hangs the attach as hard as a silent
        // one. The empty frame URL is the whole difference.
        Assert.Equal(Wedge.Uncommitted, Targets.Verdict(Uncommitted));
    }

    [Fact]
    public void AboutBlankIsADocumentAndNotAWedge()
    {
        // The distinction the empty string turns on: `about:blank` is a page
        // that committed, and a tab sitting on one is the most ordinary thing
        // here.
        Assert.Null(Targets.Verdict(Blank));
    }

    [Fact]
    public void ALoadedPageIsLeftAlone() => Assert.Null(Targets.Verdict(Healthy));

    [Fact]
    public void AnErrorReplyIsNotReadAsAWedge()
    {
        // It is still an answer, so the renderer is alive; it is just not one a
        // frame can be read out of. The remedies stop navigations, so a reply
        // nobody planned for is a bad reason to fire one.
        Assert.Null(Targets.Verdict(Refused));
    }

    // --- The summary line `status` prints (ticket 042).

    [Fact]
    public void NothingWedgedReadsAsNone()
    {
        // Not "0", and not an empty line: a human reading `status` because the
        // tool stopped answering needs the absence stated.
        Assert.Equal("none", Summary([]));
    }

    [Fact]
    public void EachWedgeIsCountedUnderItsOwnName()
    {
        Assert.Equal("2 silent, 1 uncommitted",
            Summary([Wedge.Silent, Wedge.Uncommitted, Wedge.Silent]));
    }

    [Fact]
    public void TheOrderDoesNotFollowWhicheverTabAnsweredFirst()
    {
        // Declaration order, so the same browser reads the same way twice.
        Assert.Equal(Summary([Wedge.Uncommitted, Wedge.Silent]),
                     Summary([Wedge.Silent, Wedge.Uncommitted]));
    }

    /// <summary>
    /// The counting half of <see cref="Targets.StuckSummary"/>, given the wedges
    /// rather than a browser to find them in.
    /// </summary>
    private static string Summary(Wedge[] found)
    {
        var counts = new Dictionary<Wedge, int>();
        foreach (Wedge wedge in found)
        {
            counts[wedge] = counts.GetValueOrDefault(wedge) + 1;
        }

        return counts.Count == 0
            ? "none"
            : string.Join(", ", Enum.GetValues<Wedge>().Where(counts.ContainsKey)
                .Select(w => $"{counts[w]} {w.Value()}"));
    }

    // --- The opener map, which is how a popup finds its lane (ticket 040).

    [Fact]
    public void APopupsOpenerIsReadOutOfTheTargetList()
    {
        JsonNode reply = JsonNode.Parse("""
            {"id": 1, "result": {"targetInfos": [
              {"targetId": "PARENT", "type": "page", "openerId": ""},
              {"targetId": "POPUP", "type": "page", "openerId": "PARENT"},
              {"targetId": "WORKER", "type": "service_worker", "openerId": "PARENT"}
            ]}}
            """)!;
        IReadOnlyDictionary<string, string> openers = Targets.OpenersOf(reply);
        // Only the popup: a parent with no opener has nothing to record, and a
        // service worker is not a tab any lane can own.
        Assert.Equal(new Dictionary<string, string> { ["POPUP"] = "PARENT" }, openers);
    }

    [Fact]
    public void AnAnswerlessOpenerQueryIsAnEmptyMapRatherThanAFailure()
    {
        // Adoption is an improvement over leaving a tab unowned, never a
        // precondition for the caller's actual work.
        Assert.Empty(Targets.OpenersOf(null));
    }
}
