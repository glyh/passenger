// MCP frontend.
//
// The second consumer of the service layer, alongside the CLI. Two differences
// shape the tool design:
//
// 1. Handoff does not block by default. A tool call that hangs for five minutes
//    while someone finds a captcha is a bad citizen, so a blocked page returns
//    immediately and the agent decides what to do -- typically ask the user, then
//    call again once they've solved it. `waitSeconds` opts into blocking when
//    the caller really wants it.
//
// 2. The daemon starts on demand. A human runs `serve` first; an agent should
//    not have to know that.
//
// The doc comments here carry the *call contract* and nothing else. Operating
// knowledge -- what `blocked` misses, how to recognise a wall, that a read is one
// screen, how to read a page at all -- lives in the `using-passenger` skill,
// shipped from this repo under `skills/`. It used to live here too, and six
// skills in the owner's notes had hand-copied it by the time anyone noticed;
// ticket 032 found that a docstring and these instructions arrive on the same
// event, so a second copy here buys nothing and drifts.
//
// That division got sharper with ticket 046: extraction left this codebase
// entirely, so the *recipes* for reading a page -- including walker.js itself
// -- are in the skill directory rather than here. There is one door now, and it
// hands over `page`.
//
// **What the port buys at this door.** Ticket 023's measurement 2: the schema is
// generated from the method signature, bounds and prose included, so there is no
// hand-written JSON and no second description to drift. `[Range]` emits the same
// `minimum`/`maximum` that pydantic's `Field(ge=, le=)` did.
//
// **What it changes.** Verbs and parameters are camelCase here where the Python
// door spelled them with underscores -- `openLane`, `waitSeconds`. Deliberate:
// the generated schema takes its names from the signature, and a C# signature
// written in snake_case to preserve the old spelling would be the tail wagging
// the dog. Nothing reads the old names, so nothing breaks; an agent reads these
// descriptions and the skill, both of which say the current ones.

using System.ComponentModel;
using System.ComponentModel.DataAnnotations;
using ModelContextProtocol.Server;
using Passenger;

namespace Passenger.Mcp;

[McpServerToolType]
public static class Tools
{
    private static async Task EnsureDaemonAsync()
    {
        if (!Browser.IsUp())
        {
            await Browser.StartAsync(detach: true, hidden: true);
        }
    }

    /// <summary>
    /// Collect expired lanes, then check the caller's is still one of them.
    ///
    /// Order matters: a lane that expired between calls is still a row until the
    /// sweep reaches it, so checking first would let a doomed lane through and
    /// fail later on a dangling foreign key rather than saying LANE_NOT_FOUND.
    ///
    /// A lane holding the screen when its clock runs out takes its claim with it,
    /// and nothing else would then put the viewer away -- so the sweep that frees
    /// the last claim is also what dismisses it.
    /// </summary>
    private static void Housekeep(string? lane = null)
    {
        var holders = new HashSet<string>(Lanes.ScreenClaims());
        if (holders.Overlaps(Lanes.Sweep()) && Lanes.ScreenClaims().Count == 0)
        {
            Present.Select().Dismiss();
        }

        if (lane is not null)
        {
            Lanes.Require(lane);
        }
    }

    [McpServerTool(Name = "script")]
    [Description("""
        Open a page, drive it, and read it -- the only door onto the browser.

        Navigation, interaction and reading are all this call: `await
        page.GotoAsync(url)` then whatever you need. The reply carries what you
        returned, plus a measurement of the tab you ended on -- its character
        count and pictures, or a `blocked` record if a known vendor's wall is in
        the way.

        This tool does not interpret pages. Extraction is yours to write, and the
        `using-passenger` skill carries the recipes.

        The tab stays open and comes back in `tab`, so a sequence continues across
        calls.
        """)]
    public static async Task<ScriptOutcome> Script(
        [Description("""
            C#, run with `page` (a Playwright IPage) in scope. Use `return` to
            hand a value back; it must be JSON, so return text or a list, never a
            locator. Playwright .NET is async, so every call is awaited. To just
            read a page: await page.GotoAsync(url); return await
            page.InnerTextAsync("body"); For markdown with links and headings,
            paste the walker recipe from the `using-passenger` skill.
            """)]
        string source,
        [Description("""
            Your lane, from openLane. Tabs opened here are yours: no other
            caller sees them, and none can close them.
            """)]
        string lane,
        [Description("""
            Which tab to run against, from a previous reply or from listTabs.
            Omit for a fresh blank tab.
            """)]
        string? tab = null,
        [Description("Per-call budget for each Playwright operation.")]
        [Range(1, 600)]
        int timeoutSeconds = 60)
    {
        await EnsureDaemonAsync();
        return await Service.RunAsync(new ScriptRequest
        {
            Source = source,
            Lane = lane,
            Tab = tab,
            TimeoutS = timeoutSeconds,
        });
    }

    [McpServerTool(Name = "openLane")]
    [Description("""
        Open a lane and return its id. Call this before anything else.

        A lane owns the tabs opened in it. Nothing outside it can see or close
        them, and nothing it does reaches another caller's tabs. It collects
        itself after 30 minutes of no calls, closing its tabs -- `setTtl` when
        you know you will be waiting longer than that.
        """)]
    public static async Task<string> OpenLane()
    {
        await EnsureDaemonAsync();
        Housekeep();
        return Lanes.OpenLane();
    }

    [McpServerTool(Name = "setTtl")]
    [Description("""
        Change how long this lane may sit idle before it is collected.

        Every call naming the lane restarts its clock, so this is for waits you
        are about to start rather than for work in progress -- asking a human for
        something slow, most often.
        """)]
    public static string SetTtl(
        [Description("The lane, from openLane.")] string lane,
        [Description("Quiet time before this lane and its tabs are collected.")]
        [Range(1, 1440)]
        int minutes)
    {
        Housekeep(lane);
        Lanes.SetTtl(lane, minutes * 60);
        return $"lane {lane} expires after {minutes} min of quiet";
    }

    [McpServerTool(Name = "listTabs")]
    [Description("List the tabs in a lane, so a script can be pointed at one of them.")]
    public static async Task<List<Dictionary<string, string>>> ListTabs(
        [Description("""
            Whose tabs to list. Your own lane, or 'orphan' for tabs no lane
            claims -- what a page opened by itself, or a human opened during a
            handoff.
            """)]
        string lane)
    {
        await EnsureDaemonAsync();
        Housekeep(lane);
        Lanes.Touch(lane);
        var mine = new HashSet<string>(Lanes.TabsOf(lane));
        return [.. Targets.Pages().Where(p => mine.Contains(p.Id))
            .Select(p => new Dictionary<string, string>
            {
                ["tab"] = p.Id,
                ["url"] = p.Url,
                ["title"] = p.Title,
            })];
    }

    [McpServerTool(Name = "closeTabs")]
    [Description("Close the tabs you name, keeping the session and every other tab alive.")]
    public static async Task<string> CloseTabs(
        [Description("The lane the tabs are in.")] string lane,
        [Description("""
            Which tabs to close, from listTabs or a previous reply. Naming them
            is required: closing is not something to ask for by omission.
            """)]
        string[] tabs)
    {
        await EnsureDaemonAsync();
        Housekeep(lane);
        Lanes.Touch(lane);
        return $"closed {Lanes.CloseTabs(lane, tabs)} tab(s)";
    }

    [McpServerTool(Name = "closeAllTabs")]
    [Description("Close every tab in this lane. The lane stays open and reusable.")]
    public static async Task<string> CloseAllTabs(
        [Description("The lane to empty.")] string lane)
    {
        await EnsureDaemonAsync();
        Housekeep(lane);
        Lanes.Touch(lane);
        return $"closed {Lanes.CloseTabs(lane, Lanes.TabsOf(lane))} tab(s)";
    }

    [McpServerTool(Name = "destroyLane")]
    [Description("""
        Close this lane's tabs and end the lane. The id stops working.

        Say this when you are done, rather than leaving tabs parked until the TTL
        reaches them.
        """)]
    public static async Task<string> DestroyLane(
        [Description("The lane to end.")] string lane)
    {
        await EnsureDaemonAsync();
        Housekeep(lane);
        int closed = Lanes.CloseTabs(lane, Lanes.TabsOf(lane));
        Lanes.Destroy(lane);
        return $"closed {closed} tab(s), lane {lane} is gone";
    }

    [McpServerTool(Name = "showBrowser")]
    [Description("""
        Put the browser on screen so the user can log in or solve a challenge.

        Also how you ask for a human deliberately, not only in answer to a
        `blocked` reply.

        By default nothing here inspects the page -- the wait ends when the human
        closes the viewer, and the reply says so. `until="unblocked"` is the other
        reading: it polls the named tab until the wall stops matching. That was
        `fetch(wait_seconds=...)` before ticket 046 retired it, and it is a
        measurement rather than a guess only because the signature table is fixed.
        Whichever you wait on, read the tab afterwards and judge for yourself.
        """)]
    public static async Task<string> ShowBrowser(
        [Description("""
            Your lane. It holds a claim on the screen until you call
            hideBrowser, so another caller finishing its work cannot take the
            window away from the person you just asked for help.
            """)]
        string lane,
        [Description("""
            Bring this tab to the front first, from a previous reply or from
            listTabs, so the human lands on the page you mean.
            """)]
        string? tab = null,
        [Description("""
            Block for up to this long. 0 (default) returns as soon as it is on
            screen.
            """)]
        [Range(0, 900)]
        int waitSeconds = 0,
        [Description("""
            What ends the wait. `closed` (default) waits for the human to close
            the viewer, which is a fact about the human. `unblocked` waits for
            the vendor's wall to stop matching on `tab`, which is a fact about
            the page -- stronger, but it needs a tab and only sees walls this
            tool can name.
            """)]
        WaitFor until = WaitFor.Closed,
        [Description("""
            Send a desktop notification or webhook. Set this when the human is
            not watching this conversation -- running unattended, or on a machine
            they are not sitting at.
            """)]
        bool notifyHuman = false,
        [Description("""
            Raise the lane's idle timeout for this handoff. A human who wanders
            off for longer than the lane's TTL comes back to a tab that was
            collected.
            """)]
        [Range(1, 1440)]
        int? ttlMinutes = null)
    {
        await EnsureDaemonAsync();
        Housekeep(lane);
        if (ttlMinutes is { } minutes)
        {
            Lanes.SetTtl(lane, minutes * 60);
        }

        Lanes.Touch(lane);
        Lanes.ClaimScreen(lane);
        if (tab is not null)
        {
            await using Session session = await Session.OpenAsync();
            await Handoff.BringToFrontAsync(await session.PageForAsync(lane, tab));
        }

        IPresenter presenter = Present.Select();
        string how = await presenter.PresentAsync();
        if (notifyHuman)
        {
            Notify.Select().Notify("Agent browser needs you", how);
        }

        if (waitSeconds == 0)
        {
            Lanes.Touch(lane);
            return how;
        }

        string waited;
        if (until == WaitFor.Unblocked)
        {
            if (tab is null)
            {
                Lanes.Touch(lane);
                return $"{how} -- cannot wait on a wall with no tab named";
            }

            await using Session session = await Session.OpenAsync();
            waited = await Handoff.WaitUntilUnblockedAsync(
                await session.PageForAsync(lane, tab), waitSeconds);
        }
        else
        {
            waited = await Handoff.WaitForDismissalAsync(presenter, waitSeconds);
        }

        Lanes.Touch(lane);
        return $"{how} -- {waited}";
    }

    [McpServerTool(Name = "hideBrowser")]
    [Description("""
        Release your claim on the screen, tucking the browser away if you were
        the last one holding it.
        """)]
    public static string HideBrowser(
        [Description("""
            The lane releasing the screen. The viewer stays up while any other
            lane still holds a claim.
            """)]
        string lane)
    {
        Lanes.Require(lane);
        Lanes.Touch(lane);
        if (!Lanes.ReleaseScreen(lane))
        {
            return $"still shown: {Lanes.ScreenClaims().Count} other claim(s)";
        }

        Present.Select().Dismiss();
        return "dismissed";
    }

    [McpServerTool(Name = "browserStatus")]
    [Description("Report whether the browser is running, and what is on screen.")]
    public static Dictionary<string, string> BrowserStatus()
    {
        IPresenter presenter = Present.Select();
        NestedSession? live = Sessions.Live();
        (string host, int port) = Present.Endpoint();
        (int openTabs, int orphaned) = Lanes.Counts();
        bool up = Browser.IsUp();
        return new Dictionary<string, string>
        {
            ["daemon"] = up ? "up" : "down",
            ["presenter"] = presenter.Name.Value(),
            ["onScreen"] = presenter.Presented().ToString(),
            ["profile"] = Config.Settings.ProfileDir,
            // Named so a black screen is diagnosable: a viewer attached while
            // session reads "stale" is looking at a compositor with nothing in it.
            ["session"] = live is not null ? "live" : "stale",
            ["vnc"] = $"{host}:{port}",
            // The only number that reveals a lane you do not own. Without it
            // nothing in this tool can show tabs piling up, since every listing is
            // scoped to the caller. A count, deliberately: ids and owners would be
            // a listing, and a lane's tabs are nobody else's business.
            ["tabs"] = $"{openTabs} open, {orphaned} orphan",
            // The one thing a tab count cannot show: a tab that is holding every
            // attach open counts the same as a working one (ticket 042). Asked of
            // every tab, so it costs a websocket round trip each -- `status` is a
            // diagnostic, and a healthy tab answers in under 10ms.
            ["wedged"] = up ? Targets.StuckSummary() : "unknown",
            ["screenClaims"] = Lanes.ScreenClaims().Count.ToString(),
        };
    }
}
