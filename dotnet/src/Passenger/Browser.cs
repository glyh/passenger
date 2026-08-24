// Imperative shell: Chrome daemon lifecycle and CDP attach.
//
// Chrome is launched here rather than through LaunchPersistentContext so the
// window outlives any single command: you solve a challenge once, and every later
// call reuses that same warm, logged-in session.
//
// Launch args are deliberately minimal. Every extra flag is a way to look unlike
// a normal Chrome start, and --enable-automation (the flag that actually sets
// navigator.webdriver) is simply never passed.
//
// Playwright .NET has no sync API, so this half is an async rewrite rather than a
// transliteration -- the one structural difference ticket 023 predicted. Two
// shapes follow from it: the context manager becomes an `OpenAsync` factory plus
// `IAsyncDisposable`, and the hand-rolled websocket deadline in Targets collapses
// into a CancellationToken.

using System.Diagnostics;
using System.Net.Sockets;
using System.Text.Json;
using Microsoft.Playwright;

namespace Passenger;

public static class Browser
{
    private const int StartupPolls = 60;
    private const int PollIntervalMs = 500;

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(1) };

    public static bool IsUp()
    {
        try
        {
            using HttpResponseMessage response =
                Http.GetAsync($"{Config.CdpUrl}/json/version").GetAwaiter().GetResult();
            return response.IsSuccessStatusCode;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static bool PortTaken() =>
        Sessions.IsListening("127.0.0.1", Config.CdpPort);

    /// <summary>Launch the daemon. Returns a one-line description of what came up.</summary>
    public static async Task<string> StartAsync(bool detach = true, bool hidden = true)
    {
        if (IsUp())
        {
            return $"already running on {Config.CdpUrl}";
        }

        if (PortTaken())
        {
            throw new DaemonException(ErrorCode.PortInUse,
                $"port {Config.CdpPort} is in use by something else");
        }

        if (Launch.Which(Config.ChromeBin) is null)
        {
            throw new DaemonException(ErrorCode.ChromeNotFound,
                $"{Config.ChromeBin} not found on PATH");
        }

        // A previous session whose Chrome died leaves cage and wayvnc behind,
        // still holding the VNC port. Left alone, the session starting here cannot
        // claim that port and the stale server keeps answering viewers with the
        // empty compositor it is still attached to.
        string? reaped = Sessions.ReapStale();
        // Every row in the lane registry names a CDP target id from the browser
        // that just went away, and Chrome never hands those ids out again. Kept,
        // they would make `list_tabs` promise tabs that cannot exist.
        Lanes.Reset();

        Directory.CreateDirectory(Config.ProfileDir);
        var argv = new List<string>
        {
            Config.ChromeBin,
            $"--remote-debugging-port={Config.CdpPort}",
            $"--user-data-dir={Config.ProfileDir}",
            "--no-first-run",
            "--no-default-browser-check",
        };

        IWindowBackend backend = Launch.Select();
        if (hidden && backend.Name == BackendName.None)
        {
            // Silently launching a visible window would defeat the point of this
            // tool, and the caller would never know. Make them say so explicitly.
            throw new DaemonException(ErrorCode.CannotHide,
                "asked to start hidden, but nothing here can hide a window",
                "install cage + wayvnc (or `nix develop`), "
                + "or start it with --visible to accept a visible window");
        }

        if (hidden)
        {
            backend.Prepare();
            argv.Add($"--class={Launch.WmClass}");
            // Off-screen windows get their timers throttled, which stalls the very
            // challenge scripts we need to run. None are visible to page JS.
            argv.Add("--disable-background-timer-throttling");
            argv.Add("--disable-backgrounding-occluded-windows");
            argv.Add("--disable-renderer-backgrounding");
        }

        argv.Add("about:blank");

        LaunchPlan plan = hidden ? backend.Plan(argv) : new Launch.NoOpBackend().Plan(argv);
        Spawn(plan, detach);

        for (int i = 0; i < StartupPolls; i++)
        {
            if (IsUp())
            {
                await UnfullscreenAsync();
                string state = hidden ? "hidden" : "visible";
                string up = $"chrome up on {Config.CdpUrl} [{state}] "
                            + $"(profile: {Config.ProfileDir})";
                // A reap that could not finish is said out loud here: it means
                // something is still holding the old VNC port, so this session
                // advertises a different one than the last.
                return reaped is null ? up : $"{up}\n{reaped}";
            }

            await Task.Delay(PollIntervalMs);
        }

        throw new DaemonException(ErrorCode.DaemonStartFailed,
            "chrome did not expose CDP in time", string.Join(" ", plan.Argv));
    }

    /// <summary>
    /// Start a plan's process, detached from this one.
    ///
    /// `start_new_session=True` on the Python side put the child in its own
    /// session so it survives the command that launched it. .NET has no such
    /// switch: a child of a UseShellExecute=false start is already not killed when
    /// the parent exits, and redirecting its streams to null is what keeps it from
    /// holding this process's stdio open -- which matters because the MCP server
    /// speaks JSON-RPC there.
    /// </summary>
    private static void Spawn(LaunchPlan plan, bool detach)
    {
        var start = new ProcessStartInfo(plan.Argv[0])
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
        };
        foreach (string arg in plan.Argv.Skip(1))
        {
            start.ArgumentList.Add(arg);
        }

        foreach ((string key, string value) in plan.Env)
        {
            start.Environment[key] = value;
        }

        using Process? spawned = Process.Start(start);
        if (spawned is null)
        {
            throw new DaemonException(ErrorCode.DaemonStartFailed,
                "could not start chrome", string.Join(" ", plan.Argv));
        }

        if (detach)
        {
            // Drain to /dev/null rather than leaving the pipes to fill: a child
            // whose stdout buffer fills blocks, and cage's stderr is chatty.
            spawned.BeginOutputReadLine();
            spawned.BeginErrorReadLine();
        }
    }

    /// <summary>
    /// Give Chrome its own toolbar back, by taking it out of fullscreen.
    ///
    /// cage is a kiosk compositor: it fullscreens the client it starts, and a
    /// fullscreen Chrome hides its tab strip and toolbar. Nothing chose that --
    /// it fell out of the mechanism picked for hiding the window -- and it landed
    /// on the one moment the window is looked at. A human handed the browser to
    /// solve a captcha or finish a login could click inside the page and nothing
    /// else: no address bar to read or type into, no back button out of a
    /// redirect, no tabs.
    ///
    /// Windowed is also the more ordinary of the two shapes for a real browser to
    /// be in: a fullscreen window reports outerHeight equal to the screen with no
    /// browser UI accounting for the difference.
    ///
    /// Cheap and idempotent, so it runs on every start and again before
    /// every handoff (see Present.Prepared). When the window was never
    /// fullscreen -- --visible, or no nested backend -- the state is read and
    /// nothing is written.
    /// </summary>
    public static async Task UnfullscreenAsync()
    {
        if (!IsUp())
        {
            return;
        }

        try
        {
            await using Session session = await Session.OpenAsync();
            IPage? page = session.Context.Pages.FirstOrDefault();
            if (page is null)
            {
                return;  // no target to name a window by; nothing to fix
            }

            ICDPSession target = await session.Context.NewCDPSessionAsync(page);
            JsonElement? info = await target.SendAsync("Target.getTargetInfo");
            string targetId = info!.Value.GetProperty("targetInfo")
                                  .GetProperty("targetId").GetString()!;

            ICDPSession control = await session.Browser.NewBrowserCDPSessionAsync();
            JsonElement? window = await control.SendAsync("Browser.getWindowForTarget",
                new Dictionary<string, object> { ["targetId"] = targetId });
            JsonElement bounds = window!.Value.GetProperty("bounds");
            if (!bounds.TryGetProperty("windowState", out JsonElement state)
                || state.GetString() != "fullscreen")
            {
                return;
            }

            await control.SendAsync("Browser.setWindowBounds",
                new Dictionary<string, object>
                {
                    ["windowId"] = window.Value.GetProperty("windowId").GetInt32(),
                    ["bounds"] = new Dictionary<string, object>
                    {
                        ["windowState"] = "normal",
                    },
                });
        }
        catch (PlaywrightException)
        {
            // The daemon is up and calls work; only the toolbar is missing.
            // Raising here would report a working browser as a failed start.
        }
    }

    /// <summary>
    /// Stop this tool's browser, and nothing else. Returns what would not go.
    ///
    /// Scoped to the recorded session and to our own profile directory. The
    /// previous `pkill -x cage` matched on the program name, so it also killed
    /// cage sessions belonging to anyone else on the machine.
    /// </summary>
    public static string? Stop()
    {
        foreach (int pid in Sessions.PidsRunning($"--user-data-dir={Config.ProfileDir}"))
        {
            Sessions.Terminate(pid);
        }

        return Sessions.Teardown();
    }

    /// <summary>Which lanes these tabs belong to, for saying whose work was touched.</summary>
    internal static string LanesOf(IReadOnlyList<Target> pages)
    {
        List<string> owners = [.. pages
            .Select(p => Lanes.Owner(p.Id) ?? Lanes.Orphan)
            .Distinct().Order()];
        return owners.Count > 0 ? "lane " + string.Join(", ", owners) : "no lane";
    }
}

/// <summary>Attaches Patchright to the running Chrome and hands back pages.</summary>
public sealed class Session : IAsyncDisposable
{
    private IPlaywright playwright = null!;

    public IBrowser Browser { get; private set; } = null!;

    public IBrowserContext Context { get; private set; } = null!;

    private Session()
    {
    }

    /// <summary>
    /// The `__enter__` half, as a factory: attaching is async, and a constructor
    /// cannot be.
    /// </summary>
    public static async Task<Session> OpenAsync()
    {
        if (!Passenger.Browser.IsUp())
        {
            throw new DaemonException(ErrorCode.DaemonNotRunning, "browser not running",
                                      "start it with: passenger serve");
        }

        var session = new Session();
        session.playwright = await Playwright.CreateAsync();
        session.Browser = await session.AttachAsync();
        session.Context = session.Browser.Contexts[0];
        return session;
    }

    /// <summary>
    /// Attach -- and if a stuck tab is holding the attach open, free it.
    ///
    /// ConnectOverCDP initialises every tab that is already open and waits
    /// for all of them. So one tab left mid-navigation used to hang every later
    /// call, forever, and every entry point into this tool starts with an attach:
    /// the whole thing bricked until a human found the tab. Measured at 75s and
    /// still counting.
    ///
    /// The rescue cannot use Patchright, since Patchright is what is stuck.
    /// It goes to the browser process directly instead (see Targets), and
    /// stops the pending navigation rather than closing the tab -- whatever
    /// document that tab already had is usually the one a human was reading.
    ///
    /// Two shapes of tab do this, and they need different remedies; Targets
    /// holds the difference. Both are freed here, and neither is closed.
    /// </summary>
    private async Task<IBrowser> AttachAsync()
    {
        try
        {
            return await ConnectAsync();
        }
        catch (TimeoutException)
        {
            // A timeout here only abandons the call on this side: the driver
            // carries on attaching, and its half-finished attach is itself part
            // of what holds a tab -- it pauses every request for interception
            // and then never answers. So the driver goes first, then whatever
            // is still stuck is freed, and the retry starts from nothing.
            await RestartDriverAsync();
            IReadOnlyList<Target> stuck = Targets.Unstick();
            if (stuck.Count > 0)
            {
                // Lanes partition ownership, not availability: one attach
                // initialises every open tab, so a tab wedged in any lane hangs
                // every lane, and freeing it can stop a navigation that another
                // lane is in the middle of. Ticket 012 closed on exactly that
                // trade, a year before lanes existed. It cannot be prevented
                // while one profile means one Chrome -- so it is said out loud
                // instead, and a lane whose call died learns why.
                await Console.Error.WriteLineAsync(
                    $"   freed a wedged tab in {Passenger.Browser.LanesOf(stuck)}");
            }

            try
            {
                return await ConnectAsync();
            }
            catch (TimeoutException again)
            {
                throw new DaemonException(
                    ErrorCode.AttachTimeout,
                    $"could not attach to chrome within {Config.AttachTimeoutS}s, twice",
                    // Says what was *checked*, not what is therefore true.
                    // The old line asserted the negative -- "so this is
                    // something else" -- on the strength of a probe that knew
                    // about one of the two wedges, and sent callers to
                    // `passenger stop`, which throws away the warm logged-in
                    // session this whole tool exists to keep (ticket 042).
                    stuck.Count > 0
                        ? $"stuck in {Passenger.Browser.LanesOf(stuck)}: "
                          + string.Join(", ", stuck.Select(p => p.Url))
                        : "every tab answered its renderer probe and every "
                          + "one of them holds a document, so neither wedge "
                          + "this knows how to free is present; `passenger "
                          + "status` says what is open, and `passenger stop` "
                          + "restarts chrome at the cost of the warm session",
                    again);
            }
        }
    }

    private async Task RestartDriverAsync()
    {
        try
        {
            playwright.Dispose();
        }
        catch (Exception)
        {
            // It is being replaced; how it died does not matter.
        }

        playwright = await Playwright.CreateAsync();
    }

    /// <summary>
    /// One attach attempt, bounded.
    ///
    /// The timeout is enforced here rather than left to the driver: Playwright
    /// .NET's ConnectOverCDP takes a Timeout option, but a driver that is itself
    /// wedged mid-attach has been measured not to honour it, which is the whole
    /// of ticket 012. A CancellationToken on this side ends the wait either way.
    /// </summary>
    private async Task<IBrowser> ConnectAsync()
    {
        Task<IBrowser> attaching = playwright.Chromium.ConnectOverCDPAsync(
            Config.CdpUrl,
            new BrowserTypeConnectOverCDPOptions { Timeout = Config.AttachTimeoutS * 1000 });
        Task finished = await Task.WhenAny(
            attaching, Task.Delay(TimeSpan.FromSeconds(Config.AttachTimeoutS)));
        if (finished != attaching)
        {
            throw new TimeoutException(
                $"attach did not finish within {Config.AttachTimeoutS}s");
        }

        return await attaching;
    }

    /// <summary>
    /// A tab in this lane -- a blank one it already owns, or a new one.
    ///
    /// Reuse is lane-scoped, and that is the whole point. It used to search
    /// every open tab for an `about:blank`, so one caller's call could be
    /// handed the blank tab another caller had opened a moment ago and not yet
    /// navigated: two callers, one tab, and neither aware of the other.
    /// </summary>
    public async Task<IPage> PageAsync(string lane, bool reuse = true)
    {
        if (reuse)
        {
            var mine = new HashSet<string>(Lanes.TabsOf(lane));
            foreach (IPage existing in Context.Pages)
            {
                if (existing.Url is not ("about:blank" or "chrome://newtab/"))
                {
                    continue;
                }

                if (mine.Contains(await TargetIdAsync(existing)))
                {
                    return existing;
                }
            }
        }

        IPage opened = await Context.NewPageAsync();
        Lanes.Adopt(await TargetIdAsync(opened), lane);
        return opened;
    }

    /// <summary>
    /// The tab's CDP id -- the handle a caller holds between calls.
    ///
    /// Not the Playwright Page object, which lives only as long as this
    /// attach, and not the URL, which changes under a script's feet.
    /// </summary>
    public async Task<string> TargetIdAsync(IPage page)
    {
        ICDPSession cdp = await Context.NewCDPSessionAsync(page);
        JsonElement? info = await cdp.SendAsync("Target.getTargetInfo");
        return info!.Value.GetProperty("targetInfo").GetProperty("targetId").GetString()!;
    }

    /// <summary>
    /// The tab a call named, if this lane owns it, else a blank one.
    ///
    /// Ownership is checked before the browser is: a tab belonging to another
    /// lane and a tab that never existed have to be the same answer, or the
    /// refusal itself tells the caller that somebody else is holding it.
    /// </summary>
    public async Task<IPage> PageForAsync(string lane, string? tab)
    {
        if (tab is null)
        {
            return await PageAsync(lane, reuse: true);
        }

        if (Lanes.Owner(tab) != lane)
        {
            throw new TabNotFoundException(tab, lane, Lanes.TabsOf(lane));
        }

        foreach (IPage page in Context.Pages)
        {
            if (await TargetIdAsync(page) == tab)
            {
                return page;
            }
        }

        // Closed, or from a browser that has restarted since. Either way
        // the caller is holding a handle to something gone, and needs to
        // know which of its own tabs there are rather than a bare failure.
        throw new TabNotFoundException(tab, lane, Lanes.TabsOf(lane));
    }

    /// <summary>
    /// Close this lane's other tabs. Returns how many were closed.
    ///
    /// Was `close_other_tabs`, which closed every tab in the browser except
    /// one -- the global sweep that made one caller's cleanup another's
    /// interrupted call. It kept a tab back because Chrome exits when it
    /// loses its last one; that invariant now lives in `Lanes.CloseTabs`,
    /// which every closing path goes through.
    /// </summary>
    public async Task<int> CloseOthersAsync(string lane, IPage keep)
    {
        string kept = await TargetIdAsync(keep);
        IReadOnlyList<string> doomed = [.. Lanes.TabsOf(lane).Where(t => t != kept)];
        return Lanes.CloseTabs(lane, doomed);
    }

    /// <summary>
    /// Detach only. Closing the browser would kill the daemon and throw away
    /// the session we went to the trouble of warming up.
    /// </summary>
    public async ValueTask DisposeAsync()
    {
        try
        {
            await Browser.CloseAsync();
        }
        finally
        {
            playwright.Dispose();
        }
    }
}
