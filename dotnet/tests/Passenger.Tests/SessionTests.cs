// The session record and its process predicates.
//
// Every test here is a scar. A stale `wayvnc` serving a dead compositor while
// every status read healthy -- a black screen with nothing reporting a fault --
// and two bugs surfaced by hand during that work: a liveness check counting
// zombies as alive, and the VNC port drifting upward on every restart because
// SIGTERM is asynchronous. Neither would have been caught by review, and nothing
// but this stops either returning.
//
// These run against real processes rather than fixture text. `ReadProcState`
// reads `/proc/<pid>/stat`, and a `true` that nobody reaped is a zombie in about
// 200ms -- so the thing under test is the actual read and the actual parse, not a
// seam holding a string somebody typed. `true` and `sleep` are not cage, wayvnc
// and Chrome: nothing here starts the real stack.
//
// State is redirected in Sandbox, which is load-bearing -- see the note there
// about what a teardown would otherwise do to a live session.

using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using Passenger;
using Xunit;

namespace Passenger.Tests;

[Collection(nameof(SharedStateCollection))]
public class SessionTests : IDisposable
{
    private readonly List<Process> spawned = [];

    public void Dispose()
    {
        Sessions.Alive = Sessions.ReadProcState;
        Sessions.Delete(Sessions.SessionFile);
        Sessions.ClearViewer();
        foreach (Process child in spawned)
        {
            try
            {
                if (!child.HasExited)
                {
                    child.Kill(entireProcessTree: true);
                }

                child.WaitForExit(2000);
            }
            catch (Exception)
            {
                // Already gone.
            }

            child.Dispose();
        }

        GC.SuppressFinalize(this);
    }

    /// <summary>The process state letter, read without disturbing it.</summary>
    private static string State(int pid) =>
        File.ReadAllText($"/proc/{pid}/stat").Split(')')[^1]
            .Split(' ', StringSplitOptions.RemoveEmptyEntries)[0];

    /// <summary>
    /// A child that prints `ready` once it is, returned once it has.
    ///
    /// Every child here has to reach some state before the assertion means
    /// anything -- its argv has to be its own, its socket has to be bound -- and
    /// the tests used to wait for that by polling for the effect, 200 times at
    /// 10ms. Two seconds is a guess at a fork, an exec and an interpreter start:
    /// it held on one machine and lost in the nix sandbox, where the check went
    /// red on a test that nothing in the commit reached and green on an immediate
    /// re-run. A gate that is re-run until it passes is not one.
    ///
    /// A child that says when it is ready removes the guess instead of enlarging
    /// it. The line cannot be printed before the state exists, because the child
    /// prints it afterwards, so there is no window left to size. If the child dies
    /// first the pipe closes and the read returns empty, so a broken child fails
    /// the test rather than hanging it.
    /// </summary>
    private Process Python(string script, params string[] args)
    {
        var start = new ProcessStartInfo("python3")
        {
            RedirectStandardOutput = true,
            UseShellExecute = false,
        };
        start.ArgumentList.Add("-c");
        start.ArgumentList.Add(script);
        foreach (string arg in args)
        {
            start.ArgumentList.Add(arg);
        }

        Process child = Process.Start(start)!;
        spawned.Add(child);
        string? line = child.StandardOutput.ReadLine();
        Assert.True(line == "ready", $"child never announced itself: {line}");
        return child;
    }

    /// <summary>
    /// A pid that is exited-but-unreaped, which is what Chrome leaves in cage.
    ///
    /// Made under a parent this process does not own, and that is not incidental.
    /// .NET's `Process` installs a SIGCHLD handler and reaps every child it
    /// started the moment it exits, so a zombie created with `Process.Start`
    /// never exists to be measured -- the /proc entry is gone before the
    /// assertion reads it. Python's subprocess reaps only when asked, which is
    /// why the original test could just start `true` and look.
    ///
    /// So the zombie is a child of a small python parent that forks, lets the
    /// child exit, and then sleeps without waiting on it. The pid is printed
    /// before the `ready` line, so there is nothing to poll for.
    /// </summary>
    private int Zombie()
    {
        var start = new ProcessStartInfo("python3")
        {
            RedirectStandardOutput = true,
            UseShellExecute = false,
        };
        start.ArgumentList.Add("-c");
        start.ArgumentList.Add("""
            import os, sys, time
            pid = os.fork()
            if pid == 0:
                os._exit(0)
            print(pid, flush=True)
            print('ready', flush=True)
            time.sleep(30)
            """);
        Process parent = Process.Start(start)!;
        spawned.Add(parent);
        int zombie = int.Parse(parent.StandardOutput.ReadLine()!);
        Assert.Equal("ready", parent.StandardOutput.ReadLine());

        for (int i = 0; i < 200; i++)
        {
            if (State(zombie) == "Z")
            {
                return zombie;
            }

            Thread.Sleep(10);
        }

        Assert.Fail("no zombie to test with");
        return 0;
    }

    private int Running()
    {
        Process child = Process.Start(new ProcessStartInfo("/bin/sleep")
        {
            ArgumentList = { "30" },
            UseShellExecute = false,
        })!;
        spawned.Add(child);
        return child.Id;
    }

    private static NestedSession Record(int? chromePid = null, int? cagePid = null,
                                        int? vncPid = null)
    {
        int self = Environment.ProcessId;
        return new NestedSession
        {
            CagePid = cagePid ?? self,
            ChromePid = chromePid ?? self,
            VncPid = vncPid ?? self,
            VncHost = Config.Settings.VncHost,
            VncPort = Config.Settings.VncPort,
            CtlSocket = Sessions.CtlSocket(Config.Settings.VncPort),
            WaylandDisplay = "wayland-test",
        };
    }

    private static void Write(NestedSession record)
    {
        Directory.CreateDirectory(Config.StateDir);
        File.WriteAllText(Sessions.SessionFile, string.Join("\n",
        [
            $"cage_pid={record.CagePid}",
            $"chrome_pid={record.ChromePid}",
            $"vnc_pid={record.VncPid}",
            $"vnc_host={record.VncHost}",
            $"vnc_port={record.VncPort}",
            $"ctl_socket={record.CtlSocket}",
            $"wayland_display={record.WaylandDisplay}",
        ]));
    }

    // --- liveness ----------------------------------------------------------

    [Fact]
    public void AZombieDoesNotCountAsAlive()
    {
        // The bug: signalling a pid with 0 succeeds on an unreaped child, so a
        // session whose Chrome had died inside cage reported itself live, and the
        // viewer showed a black screen with every status agreeing it was fine.
        int zombie = Zombie();
        Assert.Equal("Z", State(zombie));  // the old check would still pass here
        Assert.False(Sessions.ReadProcState(zombie));
    }

    [Fact]
    public void ARunningProcessIsAlive() => Assert.True(Sessions.ReadProcState(Running()));

    [Fact]
    public void APidThatIsNotThereIsNotAlive() =>
        Assert.False(Sessions.ReadProcState(1 << 22));

    // --- the port ----------------------------------------------------------

    [Fact]
    public void FreePortTakesTheConfiguredPortWhenNothingHoldsIt() =>
        Assert.Equal(Config.Settings.VncPort, Sessions.FreePort());

    [Fact]
    public void FreePortStepsOverAPortSomeoneElseHolds()
    {
        // Scanned rather than fixed so a second session -- or anyone else's
        // wayvnc -- cannot silently take the port this one is about to advertise.
        using var held = new Socket(AddressFamily.InterNetwork, SocketType.Stream,
                                    ProtocolType.Tcp);
        held.Bind(new IPEndPoint(IPAddress.Parse(Config.Settings.VncHost),
                                 Config.Settings.VncPort));
        held.Listen();
        Assert.Equal(Config.Settings.VncPort + 1, Sessions.FreePort());
    }

    [Fact]
    public void TeardownGivesThePortBackBeforeItReturns()
    {
        // The port-drift regression, asserted on the port rather than on the pids.
        //
        // SIGTERM is asynchronous. A teardown that fired and forgot left the old
        // listener holding the port, so the session started immediately afterwards
        // quietly claimed a different one and the port climbed on every restart.
        //
        // The child dies *slowly* on purpose: against one that exits instantly
        // this test would pass even if StopAll never waited at all, and would be
        // green for the wrong reason.
        Process slow = Python(SlowScript, Config.Settings.VncHost,
                              Config.Settings.VncPort.ToString());
        Assert.NotEqual(Config.Settings.VncPort, Sessions.FreePort());

        Sessions.StopAll(Record(cagePid: slow.Id, vncPid: slow.Id));
        Assert.Equal(Config.Settings.VncPort, Sessions.FreePort());
    }

    private const string SlowScript = """
        import socket, signal, sys, time
        s = socket.socket(); s.bind((sys.argv[1], int(sys.argv[2]))); s.listen()
        signal.signal(signal.SIGTERM, lambda *_: (time.sleep(0.5), sys.exit(0)))
        print("ready", flush=True)
        time.sleep(30)
        """;

    private const string StubbornScript = """
        import socket, signal, sys, time
        s = socket.socket(); s.bind((sys.argv[1], int(sys.argv[2]))); s.listen()
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        print("ready", flush=True)
        time.sleep(60)
        """;

    [Fact]
    public void TeardownKillsWhatWillNotTerminate()
    {
        // The bug: the SIGTERM budget ran out and the record was unlinked anyway.
        //
        // That is the port drift above all over again, and worse -- with the
        // record gone the surviving pid is unowned, so ReapStale cannot clean up
        // after it either. It needs only a wayvnc that takes longer than two
        // seconds to die.
        Process child = Python(StubbornScript, Config.Settings.VncHost,
                               Config.Settings.VncPort.ToString());
        Assert.NotEqual(Config.Settings.VncPort, Sessions.FreePort());
        Write(Record(cagePid: child.Id, vncPid: child.Id));

        Assert.Null(Sessions.StopAll(Record(cagePid: child.Id, vncPid: child.Id)));
        Assert.Equal(Config.Settings.VncPort, Sessions.FreePort());
        Assert.Null(Sessions.Current());
    }

    [Fact]
    public void APidThatSurvivesEvenSigkillKeepsItsRecord()
    {
        // Nothing in userspace survives SIGKILL, so liveness is stubbed here --
        // the state is real (a pid in uninterruptible sleep, or one that is not
        // ours) but it cannot be produced honestly from a test.
        //
        // What matters is that the record stays: unlinking it is what makes the
        // pid unowned, and a record ReapStale can still read is the only thing
        // that keeps the port attributable to a session someone can name.
        int running = Running();
        Sessions.Alive = _ => true;
        Write(Record(cagePid: running, vncPid: running));
        string? note = Sessions.StopAll(Record(cagePid: running, vncPid: running));
        Assert.NotNull(note);
        Assert.Contains(running.ToString(), note, StringComparison.Ordinal);
        Assert.NotNull(Sessions.Current());
    }

    // --- the record --------------------------------------------------------

    [Fact]
    public void AMalformedRecordReadsAsAbsent()
    {
        // The caller's next move is to start a fresh session either way, so a
        // half-written record must not raise on the way past.
        Directory.CreateDirectory(Config.StateDir);
        File.WriteAllText(Sessions.SessionFile, "cage_pid=1\nnot a pair\nvnc_port=");
        Assert.Null(Sessions.Current());
    }

    [Fact]
    public void ASessionWhoseChromeIsGoneIsNotLive()
    {
        // The black screen, exactly: cage and wayvnc still up, Chrome dead.
        // `Alive` is keyed on Chrome because cage outliving it is the stale state
        // the record exists to detect.
        int zombie = Zombie(), running = Running();
        Write(Record(chromePid: zombie, cagePid: running, vncPid: running));
        Assert.NotNull(Sessions.Current());
        Assert.Null(Sessions.Live());
    }

    // --- the viewer --------------------------------------------------------

    [Fact]
    public void ViewerPidIsKeyedOnThePidNotTheName()
    {
        // So a VNC client the user opened for something else is never mistaken
        // for ours, in either direction.
        int running = Running();
        Sessions.RecordViewer(running);
        Assert.Equal(running, Sessions.ViewerPid());
        Sessions.ClearViewer();
        Assert.Null(Sessions.ViewerPid());
    }

    [Fact]
    public void AViewerThatDiedIsNotReported()
    {
        Sessions.RecordViewer(Zombie());
        Assert.Null(Sessions.ViewerPid());
    }

    [Fact]
    public void PidsRunningMatchesOnTheCommandLine()
    {
        // Matched on argv, so the fragment has to be unique to this run. A
        // literal like "nothing-runs-with-this" is not: it appears in this file,
        // and therefore in the argv of any shell that was handed this file's text
        // -- which is how the first draft of this test failed against the process
        // that wrote it.
        string tag = "passenger-test-" + Guid.NewGuid().ToString("N");
        // Announced rather than polled for: between fork and exec the child's
        // cmdline is not yet its own, so reading /proc straight away is a race.
        // The announcement closes it, because the kernel sets the cmdline at exec
        // and the child prints only after. Walking all of /proc is also the
        // slowest possible way to ask, so a poll would get slower under precisely
        // the load that made it necessary.
        Process child = Python(
            $"import time; print('ready', flush=True); time.sleep(30)  # {tag}");
        Assert.Contains(child.Id, Sessions.PidsRunning(tag));
        Assert.Empty(Sessions.PidsRunning("absent-" + Guid.NewGuid().ToString("N")));
    }
}
