// The one thing a human types.
//
// Ticket 057 deleted the CLI: nobody had ever run it, and every verb on it but
// this one duplicated a tool at the door that actually gets used. What could not
// go is the exit from a wedged Chrome. `Browser.Stop` is the only one, and
// making it a tool was rejected on the rule this codebase has applied twice
// already -- `hide --force`, and 040's refcounted screen -- that destructive
// things a human should own do not get an agent tool. An agent that hits a
// timeout and helpfully restarts Chrome costs the owner every login on the
// machine.
//
// So it lives here, in the binary that survived, handled before the host is
// built. `Webserve.ServeIfAsked` set that pattern; this follows it with one
// difference in shape. `--serve-viewer` is a flag because nothing but this
// process ever types it. `stop` is a verb because a person does.
//
// **stdout is this file's to use.** Everywhere else in this project it belongs
// to the protocol, and a stray line there corrupts the JSON-RPC stream. Reaching
// here means no server was started and none will be: the process says one thing
// and exits.

using Passenger;

namespace Passenger.Mcp;

internal static class Stop
{
    private const string Verb = "stop";
    private const string ForceFlag = "--force";

    private const string Usage = """
        usage: Passenger.Mcp              speak MCP over stdio (what a client runs)
               Passenger.Mcp stop [--force]   stop chrome, losing the warm session
        """;

    /// <summary>
    /// Handle a human's argv, or say why it was not one. Null means the caller
    /// passed nothing and the server should start normally.
    /// </summary>
    internal static int? IfAsked(string[] args)
    {
        if (args.Length == 0)
        {
            return null;
        }

        // Anything else is a mistake, and the worst way to report it would be to
        // start a server: a person who typed `--help` would watch a process sit on
        // a pipe nobody is reading and conclude it had hung.
        if (args[0] != Verb || args.Length > 2
            || (args.Length == 2 && args[1] != ForceFlag))
        {
            Console.Error.WriteLine(Usage);
            return 2;
        }

        bool force = args.Length == 2;
        Lanes.Sweep();
        IReadOnlyList<string> claims = Lanes.ScreenClaims();
        IReadOnlyList<(string Lane, int Tabs)> occupied = Lanes.Occupied();

        if (!force && (claims.Count > 0 || occupied.Count > 0))
        {
            Console.Error.WriteLine(Refusal(claims, occupied));
            return 1;
        }

        Console.WriteLine(Browser.Stop() ?? "stopped");
        return 0;
    }

    /// <summary>
    /// What is about to be lost, before it is lost.
    ///
    /// Both halves are said because they fail differently. A screen claim means a
    /// person is looking at the window right now, quite possibly mid-captcha --
    /// 040 built the refcount so one lane could not take the window from another
    /// lane's human, and this is the same interruption from outside the lanes
    /// entirely. Tabs are the quieter loss: a solved login with no viewer open
    /// looks like nothing at all and is exactly what the warm session is for.
    /// </summary>
    private static string Refusal(IReadOnlyList<string> claims,
                                  IReadOnlyList<(string Lane, int Tabs)> occupied)
    {
        var lines = new List<string>();
        if (claims.Count > 0)
        {
            lines.Add($"the browser is on screen for {claims.Count} lane(s): "
                      + string.Join(", ", claims) + " -- somebody may be mid-handoff");
        }

        if (occupied.Count > 0)
        {
            lines.Add($"{occupied.Sum(lane => lane.Tabs)} tab(s) open in "
                      + $"{occupied.Count} lane(s): "
                      + string.Join(", ", occupied.Select(l => $"{l.Lane} ({l.Tabs})")));
        }

        lines.Add("stopping loses the warm logged-in session; "
                  + $"`Passenger.Mcp stop {ForceFlag}` does it anyway");
        return string.Join("\n", lines);
    }
}
