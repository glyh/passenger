// The handful of POSIX calls the BCL does not expose.
//
// The Python side reached these through `os` -- `os.getuid`, `os.kill` with an
// explicit signal. .NET has neither: `Process.Kill` sends SIGKILL and only to a
// process it can open a handle to, which is not the same act as SIGTERM to a
// recorded pid that may already be gone. Signalling a pid this tool did not
// start is load-bearing here (session teardown, dismissing the viewer), and
// escalating SIGTERM to SIGKILL is the fix ticket 024 landed, so the
// distinction cannot be given up.

using System.Runtime.InteropServices;

namespace Passenger;

internal static class Syscall
{
    public const int Sigterm = 15;
    public const int Sigkill = 9;

    // DllImport rather than the source-generated LibraryImport: these two
    // signatures are entirely blittable, so the generator would buy nothing,
    // and it requires AllowUnsafeBlocks across the whole assembly to emit code
    // neither of these needs.
    [DllImport("libc", EntryPoint = "getuid")]
    public static extern uint Getuid();

    [DllImport("libc", EntryPoint = "kill", SetLastError = true)]
    private static extern int KillRaw(int pid, int signal);

    /// <summary>
    /// Signal one process, tolerating its having already gone.
    ///
    /// Both failures the Python side caught -- ProcessLookupError and
    /// PermissionError -- are swallowed the same way, because both mean this
    /// tool is not going to be the one that stops that process.
    /// </summary>
    public static void Kill(int pid, int signal)
    {
        try
        {
            _ = KillRaw(pid, signal);
        }
        catch (DllNotFoundException)
        {
            // Not Linux. Nothing here works off Linux anyway -- cage and wayvnc
            // are Wayland -- so this is a courtesy rather than a fallback.
        }
        catch (EntryPointNotFoundException)
        {
        }
    }
}
