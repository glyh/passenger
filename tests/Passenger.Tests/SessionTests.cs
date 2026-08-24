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
// reads `/proc/<pid>/stat`, so the thing under test is the actual read and the
// actual parse, not a seam holding a string somebody typed. `sh` and `sleep` are
// not cage, wayvnc and Chrome: nothing here starts the real stack.
//
// **Nothing here runs python.** The Python suite reached for it freely, and the
// first draft of this file inherited the habit -- which would have left a port
// whose whole point is dropping that dependency unable to run its own tests
// without it. What the children need is a POSIX shell, `sleep`, and `trap`.
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
    /// A shell child that prints `ready` once it is, returned once it has.
    ///
    /// Every child here has to reach some state before the assertion means
    /// anything, and the tests this is modelled on used to wait for that by
    /// polling, 200 times at 10ms. Two seconds is a guess at a fork, an exec and
    /// an interpreter start: it held on one machine and lost in the nix sandbox,
    /// where the check went red on a test that nothing in the commit reached and
    /// green on an immediate re-run. A gate that is re-run until it passes is not
    /// one.
    ///
    /// A child that says when it is ready removes the guess instead of enlarging
    /// it. The line cannot be printed before the state exists, because the child
    /// prints it afterwards, so there is no window left to size. If the child dies
    /// first the pipe closes and the read returns null, so a broken child fails
    /// the test rather than hanging it.
    ///
    /// `name` becomes the shell's `$0`, which is how a test puts a chosen string
    /// into a real process's argv without needing a program that accepts one.
    /// </summary>
    private Process Sh(string script, string name = "sh", int[]? pidLine = null)
    {
        var start = new ProcessStartInfo("/bin/sh")
        {
            RedirectStandardOutput = true,
            UseShellExecute = false,
        };
        start.ArgumentList.Add("-c");
        start.ArgumentList.Add(script);
        start.ArgumentList.Add(name);

        Process child = Process.Start(start)!;
        spawned.Add(child);
        if (pidLine is not null)
        {
            // A script that announces a pid prints it before `ready`, so both
            // reads are ordered by the child rather than by a wait on this side.
            pidLine[0] = int.Parse(child.StandardOutput.ReadLine()!);
        }

        string? line = child.StandardOutput.ReadLine();
        Assert.True(line == "ready", $"child never announced itself: {line}");
        return child;
    }

    /// <summary>
    /// A pid that is exited-but-unreaped, which is what Chrome leaves in cage.
    ///
    /// Three approaches, and only the third survives contact.
    ///
    /// `Process.Start` cannot make one: .NET installs a SIGCHLD handler and reaps
    /// every child it started the moment it exits, so the /proc entry is gone
    /// before the assertion reads it.
    ///
    /// Forking in-process cannot either. A raw `fork` the runtime does not know
    /// about does leave a zombie -- measured, in a single-threaded probe -- but
    /// forking a runtime with xUnit's worker threads in it crashes the test host,
    /// which is how it presented: 48 of 84 tests ran and the run reported success.
    ///
    /// So the parent is a shell that stops itself. `sh` normally reaps its own
    /// background children, which is why `true &amp;` leaves nothing behind -- but a
    /// shell under SIGSTOP cannot run the reaping, so the `sleep` it backgrounded
    /// becomes a zombie and stays one. Nothing here is beyond a POSIX shell.
    ///
    /// The pid is printed before the `ready` line, so there is nothing to poll for
    /// except the second between the shell stopping and the child exiting.
    /// </summary>
    private int Zombie()
    {
        int[] announced = new int[1];
        _ = Sh("""
            sleep 1 &
            echo $!
            echo ready
            kill -s STOP $$
            """, pidLine: announced);
        int zombie = announced[0];
        for (int i = 0; i < 300; i++)
        {
            if (!File.Exists($"/proc/{zombie}/stat"))
            {
                break;
            }

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
        // Not "/bin/sleep": that path is an FHS assumption a Nix build sandbox
        // does not make. A bare name lets Process.Start resolve it off PATH,
        // which coreutils occupies everywhere this runs.
        Process child = Process.Start(new ProcessStartInfo("sleep")
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
        //
        // The listener is this process, which is why no child is needed: the
        // question is only what the scan reads, not who is answering.
        using var held = new Socket(AddressFamily.InterNetwork, SocketType.Stream,
                                    ProtocolType.Tcp);
        held.Bind(new IPEndPoint(IPAddress.Parse(Config.Settings.VncHost),
                                 Config.Settings.VncPort));
        held.Listen();
        Assert.Equal(Config.Settings.VncPort + 1, Sessions.FreePort());
    }

    // A child that will not die at once: the trap runs only after the foreground
    // `sleep` returns, and then sleeps again before exiting. So SIGTERM takes
    // between one and two seconds to take effect, which is the whole point --
    // against a child that exits instantly these tests would pass even if StopAll
    // never waited at all, and would be green for the wrong reason.
    private const string SlowScript = """
        trap 'sleep 1; exit 0' TERM
        echo ready
        while :; do sleep 1; done
        """;

    // And one that never leaves on its own. `trap '' TERM` ignores the signal
    // outright, which is what a wayvnc wedged in a syscall looks like from here.
    private const string StubbornScript = """
        trap '' TERM
        echo ready
        while :; do sleep 1; done
        """;

    [Fact]
    public void TeardownWaitsForTheProcessToActuallyGo()
    {
        // The port-drift regression. SIGTERM is asynchronous: a teardown that
        // fired and forgot left the old listener holding the port, so the session
        // started immediately afterwards quietly claimed a different one and the
        // port climbed on every restart.
        //
        // Asserted on the pid and the elapsed time rather than on the port, which
        // is where the Python version put it. Holding a TCP port needs a program
        // that can bind one, and a POSIX shell cannot -- the original reached for
        // python to get it, which is the dependency this port exists to drop. The
        // port-reading half is covered on its own by
        // FreePortStepsOverAPortSomeoneElseHolds; what is left to prove here is
        // that StopAll does not return until the process is gone, which is the
        // mechanism the port was only ever the symptom of.
        Process slow = Sh(SlowScript);
        var clock = Stopwatch.StartNew();
        Sessions.StopAll(Record(cagePid: slow.Id, vncPid: slow.Id));
        clock.Stop();

        Assert.False(Sessions.ReadProcState(slow.Id));
        Assert.True(clock.ElapsedMilliseconds >= 900,
            $"returned in {clock.ElapsedMilliseconds}ms, so it did not wait");
    }

    [Fact]
    public void TeardownKillsWhatWillNotTerminate()
    {
        // The bug: the SIGTERM budget ran out and the record was unlinked anyway.
        //
        // That is the port drift above all over again, and worse -- with the
        // record gone the surviving pid is unowned, so ReapStale cannot clean up
        // after it either. It needs only a wayvnc that takes longer than two
        // seconds to die.
        Process child = Sh(StubbornScript);
        Write(Record(cagePid: child.Id, vncPid: child.Id));

        Assert.Null(Sessions.StopAll(Record(cagePid: child.Id, vncPid: child.Id)));
        Assert.False(Sessions.ReadProcState(child.Id));
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
        //
        // The tag rides in as the shell's `$0`, so it is in a real process's
        // cmdline without needing a program that takes an arbitrary argument.
        string tag = "passenger-test-" + Guid.NewGuid().ToString("N");
        Process child = Sh("""
            echo ready
            while :; do sleep 1; done
            """, name: tag);
        Assert.Contains(child.Id, Sessions.PidsRunning(tag));
        Assert.Empty(Sessions.PidsRunning("absent-" + Guid.NewGuid().ToString("N")));
    }
}
