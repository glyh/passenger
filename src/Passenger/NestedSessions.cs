// Imperative shell: which cage/wayvnc/viewer processes are *ours*.
//
// Every process this tool starts is nested one inside another -- cage holds
// wayvnc and Chrome, and a viewer connects to that wayvnc from outside. Nothing
// in the process table says which of them belong together, so this module keeps
// the one record that does.
//
// Without it the correlation was guessed by name, and both directions of the
// guess were wrong. A second cage session inherited the first one's hardcoded
// VNC port, so its wayvnc lost the bind and died while the *stale* one kept
// serving an empty compositor -- a viewer that connects and shows black. In the
// other direction `pkill -x cage` and a `pkill -x` on the viewer's binary reached
// every such process on the machine, so this tool tore down sessions and remote
// desktops that were never its own.
//
// The record is written by the session script itself, from inside cage, because
// that is the only place that can observe what actually came up: the display it
// got, and the pids of the processes cage really started.

using System.Net.Sockets;

namespace Passenger;

/// <summary>One live cage session, as reported from inside it.</summary>
public sealed record NestedSession
{
    public required int CagePid { get; init; }
    public required int ChromePid { get; init; }
    public required int VncPid { get; init; }
    public required string VncHost { get; init; }
    public required int VncPort { get; init; }
    public required string CtlSocket { get; init; }
    public required string WaylandDisplay { get; init; }

    /// <summary>
    /// Chrome is the session: cage exists only to hold it.
    ///
    /// Keyed on Chrome rather than on cage because cage outliving a dead
    /// Chrome is exactly the stale state this record has to detect -- that is
    /// the shape the black screen came in.
    /// </summary>
    public bool Alive => Sessions.IsAlive(ChromePid);
}

public static class Sessions
{
    public static string SessionFile => Path.Combine(Config.StateDir, "session.env");
    public static string ViewerFile => Path.Combine(Config.StateDir, "viewer.pid");

    private const int PortScan = 64;
    private const int ExitPolls = 20;
    private const int KillPolls = 20;
    private const int PollIntervalMs = 100;

    /// <summary>
    /// How liveness is decided. Replaced only by the suite, and only for the one
    /// case that cannot be produced honestly: nothing in userspace survives
    /// SIGKILL, so a pid that does -- one in uninterruptible sleep, or one that is
    /// not ours -- has to be stood in for. The Python tests monkeypatched the same
    /// function for the same test.
    /// </summary>
    public static Func<int, bool> Alive { get; set; } = ReadProcState;

    public static bool IsAlive(int pid) => Alive(pid);

    /// <summary>
    /// Is this pid a running process?
    ///
    /// A zombie does not count. Chrome dying inside cage leaves an unreaped child
    /// whose pid still answers signal 0, so a liveness check built on kill(2)
    /// alone reports a dead session as live -- which is the state that had a
    /// viewer showing a black screen with everything claiming to be fine.
    /// </summary>
    public static bool ReadProcState(int pid)
    {
        string stat;
        try
        {
            stat = File.ReadAllText($"/proc/{pid}/stat");
        }
        catch (FileNotFoundException)
        {
            return false;
        }
        catch (DirectoryNotFoundException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return true;  // exists, owned by someone else
        }
        catch (IOException)
        {
            return false;
        }

        // Field 3 is the state code, after the comm field, which may itself
        // contain spaces or brackets -- so split from the last ')' rather than
        // tokenising the whole line.
        int close = stat.LastIndexOf(')');
        if (close < 0)
        {
            return false;
        }

        string[] rest = stat[(close + 1)..]
            .Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return rest.Length > 0 && rest[0] != "Z";
    }

    /// <summary>Pure: the `key=value` lines of a session record.</summary>
    public static IReadOnlyDictionary<string, string> ParseRecord(string text)
    {
        var pairs = new Dictionary<string, string>();
        foreach (string line in text.Split('\n'))
        {
            int split = line.IndexOf('=');
            if (split > 0)
            {
                pairs[line[..split]] = line[(split + 1)..].TrimEnd('\r');
            }
        }

        return pairs;
    }

    /// <summary>
    /// Pure: a record's fields as a session, or null if it does not describe one.
    ///
    /// A malformed or half-written record is treated as absent rather than
    /// raising: the caller's next move is to start a fresh session either way.
    /// </summary>
    public static NestedSession? SessionOf(IReadOnlyDictionary<string, string> fields)
    {
        try
        {
            int port = int.Parse(fields["vnc_port"]);
            if (port is < 1 or > 65535)
            {
                return null;
            }

            return new NestedSession
            {
                CagePid = int.Parse(fields["cage_pid"]),
                ChromePid = int.Parse(fields["chrome_pid"]),
                VncPid = int.Parse(fields["vnc_pid"]),
                VncHost = fields["vnc_host"],
                VncPort = port,
                CtlSocket = fields["ctl_socket"],
                WaylandDisplay = fields["wayland_display"],
            };
        }
        catch (Exception e) when (e is KeyNotFoundException or FormatException
                                       or OverflowException)
        {
            return null;
        }
    }

    /// <summary>The recorded session, or null if there is no readable one.</summary>
    public static NestedSession? Current()
    {
        try
        {
            return SessionOf(ParseRecord(File.ReadAllText(SessionFile)));
        }
        catch (Exception)
        {
            return null;
        }
    }

    public static NestedSession? Live()
    {
        NestedSession? session = Current();
        return session is not null && session.Alive ? session : null;
    }

    /// <summary>
    /// First free port at or above the configured one.
    ///
    /// Scanned rather than fixed so a second session -- or anyone else's wayvnc --
    /// cannot silently take the port this one is about to advertise.
    /// </summary>
    public static int FreePort()
    {
        for (int port = Config.Settings.VncPort;
             port < Config.Settings.VncPort + PortScan; port++)
        {
            if (!IsListening(Config.Settings.VncHost, port))
            {
                return port;
            }
        }

        return Config.Settings.VncPort;
    }

    internal static bool IsListening(string host, int port, int timeoutMs = 300)
    {
        try
        {
            using var probe = new TcpClient();
            IAsyncResult pending = probe.BeginConnect(host, port, null, null);
            bool answered = pending.AsyncWaitHandle.WaitOne(timeoutMs);
            if (!answered)
            {
                return false;
            }

            probe.EndConnect(pending);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>
    /// Per-port control socket.
    ///
    /// wayvnc refuses to start when another instance holds the default one, which
    /// is how the second session lost its VNC server without anything reporting it.
    /// </summary>
    public static string CtlSocket(int port) =>
        Path.Combine(Config.StateDir, $"wayvnc-{port}.sock");

    /// <summary>
    /// Tear down a recorded session whose Chrome is gone. Returns what it killed.
    ///
    /// Called before starting a new one so the dead session cannot keep holding
    /// the VNC port that the new session needs to advertise.
    /// </summary>
    public static string? ReapStale()
    {
        NestedSession? session = Current();
        if (session is null || session.Alive)
        {
            return null;
        }

        string? survived = StopAll(session);
        string reaped = $"reaped stale session on :{session.VncPort}";
        return survived is null ? reaped : $"{reaped}; {survived}";
    }

    /// <summary>Stop only the processes this record names. Returns what would not go.</summary>
    public static string? Teardown()
    {
        NestedSession? session = Current();
        return session is null ? null : StopAll(session);
    }

    /// <summary>
    /// Stop a session's processes. Returns a note if any of them survived.
    ///
    /// Waited on rather than fired and forgotten: SIGTERM is asynchronous, so a
    /// session started immediately afterwards would still find the old listener
    /// holding the port and quietly claim a different one, drifting upward on
    /// every restart.
    ///
    /// The wait used to end in a shrug -- the budget ran out and the record was
    /// unlinked regardless, which is that same drift with the record that names
    /// the surviving pid deleted, so `ReapStale` could not clean up after it
    /// either. SIGTERM is now escalated, and the record is kept in the one case
    /// where even that fails, because an unowned listener is the worse half of
    /// the bug.
    /// </summary>
    /// <summary>
    /// Public so the suite can assert the port is back before this returns, which
    /// is the regression ticket 024 landed for. Nothing else calls it directly:
    /// <see cref="Teardown"/> and <see cref="ReapStale"/> are the ways in.
    /// </summary>
    public static string? StopAll(NestedSession session)
    {
        // Deduplicated so a record that names one process twice cannot report it
        // twice in the note.
        List<int> pids = new[] { session.VncPid, session.CagePid }.Distinct().ToList();
        foreach (int pid in pids)
        {
            Syscall.Kill(pid, Syscall.Sigterm);
        }

        List<int> survivors = WaitForExit(pids, ExitPolls);
        if (survivors.Count == 0)
        {
            Forget(session);
            return null;
        }

        foreach (int pid in survivors)
        {
            Syscall.Kill(pid, Syscall.Sigkill);
        }

        survivors = WaitForExit(survivors, KillPolls);
        if (survivors.Count == 0)
        {
            Forget(session);
            return null;
        }

        // Deliberately keeps the record, and with it the control socket the
        // survivor may still be serving: it is the only thing that ties this port
        // to a session anyone can name, and `ReapStale` reads it on the next run.
        return $"pid {string.Join(", ", survivors)} survived SIGKILL; "
               + $":{session.VncPort} is still held, session record kept";
    }

    /// <summary>Drop the per-port state, now that nothing is left to own it.</summary>
    private static void Forget(NestedSession session)
    {
        Delete(session.CtlSocket);
        Delete(SessionFile);
    }

    /// <summary>
    /// Unlink, tolerating a path that was never there. Public because the suite
    /// clears the record between tests, and because <see cref="ClearViewer"/> is
    /// the same act by another name.
    /// </summary>
    public static void Delete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception)
        {
            // Already gone, or never ours to remove.
        }
    }

    /// <summary>Poll until every pid is gone, and report those that are not.</summary>
    private static List<int> WaitForExit(List<int> pids, int polls)
    {
        for (int i = 0; i < polls; i++)
        {
            if (!pids.Any(IsAlive))
            {
                return [];
            }

            Thread.Sleep(PollIntervalMs);
        }

        return [.. pids.Where(IsAlive)];
    }

    /// <summary>
    /// Pids whose command line contains <paramref name="fragment"/>.
    ///
    /// Reads /proc directly rather than shelling out to pgrep: the match is the
    /// security-relevant part of stopping the right processes, and doing it here
    /// makes it an ordinary function -- inspectable, and testable without
    /// spawning anything.
    /// </summary>
    public static IReadOnlyList<int> PidsRunning(string fragment)
    {
        var found = new List<int>();
        byte[] needle = System.Text.Encoding.UTF8.GetBytes(fragment);
        foreach (string entry in Directory.EnumerateDirectories("/proc"))
        {
            string name = Path.GetFileName(entry);
            if (!int.TryParse(name, out int pid))
            {
                continue;
            }

            byte[] cmdline;
            try
            {
                cmdline = File.ReadAllBytes(Path.Combine(entry, "cmdline"));
            }
            catch (Exception)
            {
                continue;  // exited between listing and reading
            }

            if (Contains(cmdline, needle))
            {
                found.Add(pid);
            }
        }

        return found;
    }

    /// <summary>
    /// Substring search over raw bytes.
    ///
    /// Bytes rather than a decoded string because /proc/pid/cmdline separates its
    /// arguments with NUL, and decoding it would either lose those boundaries or
    /// fail on a command line that is not valid UTF-8.
    /// </summary>
    private static bool Contains(byte[] haystack, byte[] needle)
    {
        if (needle.Length == 0 || haystack.Length < needle.Length)
        {
            return needle.Length == 0;
        }

        return haystack.AsSpan().IndexOf(needle.AsSpan()) >= 0;
    }

    /// <summary>SIGTERM one process, tolerating its having already gone.</summary>
    public static void Terminate(int pid) => Syscall.Kill(pid, Syscall.Sigterm);

    public static void RecordViewer(int pid)
    {
        Directory.CreateDirectory(Config.StateDir);
        File.WriteAllText(ViewerFile, pid.ToString());
    }

    /// <summary>
    /// The viewer this tool spawned, if it is still running.
    ///
    /// Checked by pid and not by name so that a VNC client the user opened for
    /// something else is never mistaken for ours -- in either direction.
    /// </summary>
    public static int? ViewerPid()
    {
        try
        {
            int pid = int.Parse(File.ReadAllText(ViewerFile).Trim());
            return IsAlive(pid) ? pid : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    public static void ClearViewer() => Delete(ViewerFile);
}
