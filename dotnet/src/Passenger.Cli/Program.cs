// The CLI boundary.
//
// System.CommandLine lives here and nowhere else: core modules raise domain
// errors and return models, and this is the single place that decides what a
// failure looks like on a terminal.
//
// It replaces cyclopts, which was the third of ticket 023's owed measurements
// and the one recorded as unchosen. The shapes differ in one way worth naming:
// cyclopts read the parameter names, types and help text off the function
// signature and its docstring, so a command was one function. System.CommandLine
// wants each option constructed, so the prose that was a docstring is a
// Description here. That is more lines for the same contract, and it is the
// argument [026](one description, two doors) is about.

using System.CommandLine;
using System.Text.Json;
using Passenger;

// Before anything else: the detached re-exec that serves the viewer page.
// Not a verb, so it never reaches the parser.
if (Webserve.ServeIfAsked(args))
{
    return 0;
}

RootCommand root = new(
    "Reach web pages through a real, logged-in Chrome, "
    + "with a human handoff when a site puts up a challenge.");

// --- shared options -----------------------------------------------------
//
// One instance per option, reused across commands, so `--lane` means the same
// thing and reads the same way at every verb.

Option<string> LaneOption(string description) =>
    new("--lane") { Description = description, DefaultValueFactory = _ => Lanes.Cli };

// --- script -------------------------------------------------------------

Option<string> scriptLane = LaneOption(
    "Which lane owns the tab. Defaults to the reserved `cli` lane.");
Option<string?> scriptTab = new("--tab")
{
    Description = "Tab id to run against, from `tabs`. Must be a tab this lane "
                  + "owns; another lane's is refused exactly as a closed one is. "
                  + "Omitted means a fresh blank tab.",
};
Option<int> scriptTimeout = new("--timeout")
{
    Description = "Seconds each Playwright operation inside the script may take.",
    DefaultValueFactory = _ => 60,
};
Option<bool> scriptJson = new("--json") { Description = "Print the whole outcome as JSON." };
Argument<string> scriptFile = new("file")
{
    Description = "Script to run. Defaults to stdin, so it reads from a heredoc.",
    DefaultValueFactory = _ => "-",
};

Command script = new("script",
    "Run a Playwright script against a tab, and print where it ends up.\n\n"
    + "The only door onto a page, at either surface, since ticket 046 retired "
    + "`fetch`: navigate with `await page.GotoAsync(url)`, drive whatever needs "
    + "driving, and return what you want. This tool does not interpret pages -- "
    + "the recipes for reading one live in the `using-passenger` skill, next to "
    + "walker.js.")
{
    scriptFile, scriptLane, scriptTab, scriptTimeout, scriptJson,
};
script.SetAction(async (parse, _) =>
{
    string file = parse.GetValue(scriptFile)!;
    string source = file == "-"
        ? await Console.In.ReadToEndAsync()
        : await File.ReadAllTextAsync(file);
    ScriptOutcome outcome = await Service.RunAsync(new ScriptRequest
    {
        Source = source,
        Lane = parse.GetValue(scriptLane)!,
        Tab = parse.GetValue(scriptTab),
        TimeoutS = parse.GetValue(scriptTimeout),
        AsJson = parse.GetValue(scriptJson),
    });
    return RenderScript(outcome, parse.GetValue(scriptJson));
});
root.Subcommands.Add(script);

// --- tabs ---------------------------------------------------------------

Option<string> tabsLane = LaneOption(
    "Whose tabs to list. `orphan` holds the ones no lane claims -- opened by a "
    + "page itself, or by a human during a handoff.");
Command tabs = new("tabs", "List a lane's tabs and their ids, for `script --tab`.")
{
    tabsLane,
};
tabs.SetAction(parse =>
{
    Lanes.Sweep();
    var mine = new HashSet<string>(Lanes.TabsOf(parse.GetValue(tabsLane)!));
    foreach (Target page in Targets.Pages().Where(p => mine.Contains(p.Id)))
    {
        string title = page.Title.Length > 40 ? page.Title[..40] : page.Title;
        Console.WriteLine($"{page.Id}  {title,-40}  {page.Url}");
    }

    return 0;
});
root.Subcommands.Add(tabs);

// --- open ---------------------------------------------------------------

Argument<string> openUrl = new("url") { Description = "Where to navigate." };
Option<bool> openShow = new("--show") { Description = "Also put the browser on screen." };
Option<string> openLane = LaneOption("Which lane owns the tab.");
Command open = new("open",
    "Park a URL in a tab, without putting the window on screen.\n\n"
    + "Navigating and displaying are separate on purpose: the window should only "
    + "appear when a human is actually needed. Pass --show, or run `show` "
    + "afterwards, when you want to look at it -- to log in, typically.")
{
    openUrl, openShow, openLane,
};
open.SetAction(async (parse, _) =>
{
    string lane = parse.GetValue(openLane)!;
    bool show = parse.GetValue(openShow);
    Lanes.Require(lane);
    await using (Session session = await Session.OpenAsync())
    {
        Microsoft.Playwright.IPage page = await session.PageAsync(lane, reuse: false);
        await page.GotoAsync(parse.GetValue(openUrl)!, new()
        {
            WaitUntil = Microsoft.Playwright.WaitUntilState.DOMContentLoaded,
            Timeout = 60000,
        });
        if (show)
        {
            Lanes.ClaimScreen(lane);
            await Console.Error.WriteLineAsync(await Present.Select().PresentAsync());
            await Handoff.BringToFrontAsync(page);
        }
    }

    string hint = show ? "" : " -- run `passenger show` to log in there";
    Console.WriteLine($"opened {parse.GetValue(openUrl)}{hint}");
    return 0;
});
root.Subcommands.Add(open);

// --- close-tabs ---------------------------------------------------------

Argument<string[]> doomed = new("tabs")
{
    Description = "Which tabs to close. Omitted means every tab in the lane; on "
                  + "the CLI that is a human saying it out loud, where the MCP "
                  + "surface makes it a separate verb so an agent cannot ask for "
                  + "it by forgetting an argument.",
    Arity = ArgumentArity.ZeroOrMore,
};
Option<string> closeLane = LaneOption(
    "Which lane to close them in. `orphan` for tabs no lane claims.");
Command closeTabs = new("close-tabs",
    "Close tabs in a lane, keeping the browser alive.\n\n"
    + "Tabs outlive the command that opened them by design -- that is what keeps "
    + "a solved challenge warm -- so `open` and interrupted calls leave them "
    + "behind.")
{
    doomed, closeLane,
};
closeTabs.SetAction(parse =>
{
    Lanes.Sweep();
    string lane = parse.GetValue(closeLane)!;
    string[] named = parse.GetValue(doomed) ?? [];
    IReadOnlyList<string> targets = named.Length > 0 ? named : Lanes.TabsOf(lane);
    Console.WriteLine($"closed {Lanes.CloseTabs(lane, targets)} tab(s)");
    return 0;
});
root.Subcommands.Add(closeTabs);

// --- serve / stop -------------------------------------------------------

Option<bool> foreground = new("--foreground")
{
    Description = "Keep the daemon attached to this terminal.",
};
Option<bool> visible = new("--visible")
{
    Description = "Skip hiding; leave the window on screen.",
};
Command serve = new("serve", "Start the Chrome daemon.") { foreground, visible };
serve.SetAction(async (parse, _) =>
{
    Console.WriteLine(await Browser.StartAsync(
        detach: !parse.GetValue(foreground), hidden: !parse.GetValue(visible)));
    return 0;
});
root.Subcommands.Add(serve);

Command stop = new("stop", "Kill the daemon and its compositor.");
stop.SetAction(_ =>
{
    string? survived = Browser.Stop();
    Console.WriteLine(survived ?? "stopped");
    return 0;
});
root.Subcommands.Add(stop);

// --- show / hide --------------------------------------------------------

Option<string> showLane = LaneOption("Which lane is claiming the screen.");
Command show = new("show", "Put the browser in front of you.") { showLane };
show.SetAction(async (parse, _) =>
{
    string lane = parse.GetValue(showLane)!;
    Lanes.Require(lane);
    Lanes.ClaimScreen(lane);
    IPresenter presenter = Present.Select();
    Console.WriteLine($"{await presenter.PresentAsync()} [{presenter.Name.Value()}]");
    return 0;
});
root.Subcommands.Add(show);

Option<string> hideLane = LaneOption("Which lane is releasing the screen.");
Option<bool> hideForce = new("--force")
{
    Description = "Dismiss even while another lane holds a claim. The human's "
                  + "override: an agent has no equivalent, because taking the "
                  + "window from somebody mid-captcha is the interference lanes "
                  + "exist to stop.",
};
Command hide = new("hide",
    "Tuck the browser away again, if nobody else is still looking.")
{
    hideLane, hideForce,
};
hide.SetAction(parse =>
{
    IPresenter presenter = Present.Select();
    bool last = Lanes.ReleaseScreen(parse.GetValue(hideLane)!);
    if (!last && !parse.GetValue(hideForce))
    {
        Console.WriteLine($"still shown: {Lanes.ScreenClaims().Count} other claim(s) "
                          + "-- pass --force to dismiss anyway");
        return 0;
    }

    presenter.Dismiss();
    Console.WriteLine($"dismissed [{presenter.Name.Value()}]");
    return 0;
});
root.Subcommands.Add(hide);

// --- status -------------------------------------------------------------

Command status = new("status", "Show daemon, window, and open tabs.");
status.SetAction(_ =>
{
    IWindowBackend launcher = Launch.Select();
    IPresenter presenter = Present.Select();
    bool up = Browser.IsUp();
    Console.WriteLine($"daemon:    {(up ? "up" : "down")} ({Config.Settings.CdpUrl})");
    Console.WriteLine($"launch:    {launcher.Name.Value()}");
    Console.WriteLine($"presenter: {presenter.Name.Value()} "
                      + $"({(presenter.Presented() ? "showing" : "hidden")})");
    NestedSession? live = Sessions.Live();
    (string host, int port) = Present.Endpoint();
    Console.WriteLine($"session:   {(live is not null ? "live" : "stale")} "
                      + $"(vnc {host}:{port})");
    Console.WriteLine($"profile:   {Config.Settings.ProfileDir}");
    // What the tool can call `blocked` -- a fixed table, so it belongs to no
    // session and needs no command of its own. `passenger signatures` was
    // that command, and it existed to curate a learned list that ticket 019
    // removed; printing a constant was all it had left to do. It says the
    // useful half here, where a human already looks when a call surprised
    // them, and everything not on this line arrives as ordinary content.
    Console.WriteLine("recognises: "
                      + string.Join(", ", Detect.Builtin.Select(s => s.Name)));
    if (up)
    {
        // A count, not a listing. A lane sees only its own tabs, and that
        // holds for a human at a terminal too -- the alternative was a global
        // view here, and it was rejected: a view that exists gets used, and
        // then the isolation is a convention rather than a property. What is
        // owed instead is a number big enough to notice, so tabs piling up in
        // a lane nobody is watching are at least visible as a total.
        (int openTabs, int orphaned) = Lanes.Counts();
        Console.WriteLine($"tabs:      {openTabs} open, {orphaned} orphan");
        // And of those, the ones that answer for nobody. A tab wedged in any
        // lane fails calls in every lane, so this is the line worth reading
        // when the tool has stopped answering (ticket 042).
        Console.WriteLine($"wedged:    {Targets.StuckSummary()}");
    }

    return 0;
});
root.Subcommands.Add(status);

// --- the one place a domain error becomes terminal behaviour -------------

try
{
    return await root.Parse(args).InvokeAsync();
}
catch (PassengerException error)
{
    await Console.Error.WriteLineAsync($"error: {error.PlainMessage}");
    if (error.Detail is not null)
    {
        await Console.Error.WriteLineAsync($"       {error.Detail}");
    }

    return ExitCodes.GetValueOrDefault(error.Code, 1);
}

static int RenderScript(ScriptOutcome outcome, bool asJson)
{
    // A script that failed exits non-zero; where it failed goes to stderr.
    switch (outcome)
    {
        case Ran ran:
            if (asJson)
            {
                Console.WriteLine(JsonSerializer.Serialize<ScriptOutcome>(
                    ran, new JsonSerializerOptions { WriteIndented = true }));
                return 0;
            }

            Console.Error.WriteLine($"   tab: {ran.Tab}");
            if (ran.Returned is not null)
            {
                Console.WriteLine(ran.Returned is string text
                    ? text
                    : JsonSerializer.Serialize(ran.Returned));
            }

            // A wall is still a failure worth exiting on, even when the script
            // itself ran: the caller asked for a page and got a challenge.
            if (ran.Page is Blocked wall)
            {
                Console.Error.WriteLine(JsonSerializer.Serialize<PageOutcome>(
                    wall, new JsonSerializerOptions { WriteIndented = true }));
                return 2;
            }

            if (ran.Page is Measured measured)
            {
                Console.Error.WriteLine(
                    $"   {measured.CharCount} chars on {measured.Url}");
            }

            return 0;

        case Failed failed:
            Console.Error.WriteLine($"   tab: {failed.Tab}");
            Console.Error.WriteLine($"[{failed.Code}] {failed.Error}");
            if (failed.Where.Length > 0)
            {
                Console.Error.WriteLine(failed.Where);
            }

            return 2;

        default:
            throw new ArgumentOutOfRangeException(nameof(outcome));
    }
}

/// <summary>
/// The single place that turns a domain error into an exit status.
///
/// A partial of the class the compiler generates for the top-level statements
/// above, so the table sits beside the handler that reads it rather than in a
/// file of its own.
/// </summary>
internal partial class Program
{
    internal static readonly Dictionary<ErrorCode, int> ExitCodes = new()
    {
        [ErrorCode.PageBlocked] = 2,
        [ErrorCode.HandoffTimeout] = 2,
        [ErrorCode.DaemonNotRunning] = 3,
    };
}
