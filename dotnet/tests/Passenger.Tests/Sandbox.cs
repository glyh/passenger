// Point every state path at a temp directory, before any test runs.
//
// This is a safety mechanism, not a convenience. Without it a test that called
// `Sessions.Teardown()` would SIGTERM the pids in the *developer's real* session
// record and unlink it, killing a live browser to run a unit test. The failure
// mode is destructive rather than red, which is why it is done once and up
// front rather than per test and forgotten in the one that matters.
//
// The Python side did this in conftest.py, before `passenger` was imported,
// because `passenger.config` read the environment once at import into
// module-level constants. Here `Config.Settings` is a settable property and the
// aliases read through it, so a module-load race is not the hazard -- but a test
// that ran before the assignment still would be, so it is a module initialiser
// on an assembly fixture rather than something a test opts into.
//
// The VNC port is pinned for a subtler reason. `Sessions.FreePort` scans upward
// from the configured port, so a test asserting it returns that port would pass
// in a sandbox (private network namespace, 5900 free) and fail on the machine of
// anyone with a live session holding 5900 -- green where nobody looks and red
// where they do.

using System.Net;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using Passenger;

namespace Passenger.Tests;

public static class Sandbox
{
    public static string StateDir { get; private set; } = "";

    [ModuleInitializer]
    public static void Redirect()
    {
        StateDir = Path.Combine(Path.GetTempPath(),
            "passenger-tests-" + Guid.NewGuid().ToString("N")[..12]);
        Directory.CreateDirectory(StateDir);
        Config.Settings = Config.Settings with
        {
            StateDir = StateDir,
            VncPort = UnusedPort(),
        };
    }

    /// <summary>A port nothing holds right now, as a base for the scan tests.</summary>
    private static int UnusedPort()
    {
        using var probe = new Socket(AddressFamily.InterNetwork, SocketType.Stream,
                                     ProtocolType.Tcp);
        probe.Bind(new IPEndPoint(IPAddress.Loopback, 0));
        return ((IPEndPoint)probe.LocalEndPoint!).Port;
    }
}
