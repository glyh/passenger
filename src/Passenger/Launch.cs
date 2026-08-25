// Imperative shell: how Chrome is launched so that it starts out hidden.
//
// Deliberately NOT headless: headless changes the fingerprint (no GPU, software
// WebGL, no window) and makes human handoff impossible. The window stays fully
// real -- it is just parked somewhere you aren't looking.
//
// There is no standard Wayland protocol for a window to hide itself, and the
// compositor-specific ways of doing it are unportable and prone to breaking, so
// there is exactly one real mechanism here plus a null object for when its
// dependencies are missing. Override the choice with PASSENGER_WM.
//
// The compositor is sway, and was cage until ticket 063. cage is a kiosk: one
// output, one fullscreened window, and no way to ask it for anything. Three
// tickets were each paying for that separately -- no data-control protocol, so
// wayvnc's clipboard had nothing to talk to (062); no text-input or
// input-method, so no IME could run in the session at all (062); one output
// forever, so two humans could never be handed two screens (041). It also
// fullscreens what it starts, which is why 006 had to spend a CDP call undoing
// half of it. sway costs 33 MiB more in the closure, offers all three, and
// answers on a socket.
//
// That reintroduces the compositor IPC this project deleted twice -- hyprctl
// and wlrctl backends both broke. The difference is ownership: those spoke to
// the *host's* compositor, upgraded on someone else's schedule. This sway is
// ours, pinned in flake.lock, running a config written here on every start.
//
// Showing the browser to a human is a separate concern -- see Present.

namespace Passenger;

/// <summary>What every launch mechanism must be able to do.</summary>
public interface IWindowBackend
{
    BackendName Name { get; }

    bool Available();

    void Prepare();

    LaunchPlan Plan(IReadOnlyList<string> argv);
}

public static class Launch
{
    public const string WmClass = "passenger";

    public static string SessionSh => Path.Combine(Config.StateDir, "session.sh");

    /// <summary>The generated sway config, rewritten on every start.</summary>
    public static string SessionConf => Path.Combine(Config.StateDir, "sway.conf");

    /// <summary>
    /// The output everything agrees on: sway creates it, wayvnc serves it, and
    /// <see cref="Geometry"/> scales it.
    ///
    /// A constant because there are now two places that must name the same one.
    /// cage had exactly one output and wayvnc could take whatever it found;
    /// under sway `create_output` can add a second (which is what 041 wants), so
    /// serving "the only one there is" stops being a description.
    /// </summary>
    public const string Output = "HEADLESS-1";

    /// <summary>
    /// The output's starting mode, and cage's old default kept deliberately.
    ///
    /// The README's measured fingerprint says `screen: 1280x720`, so changing it
    /// here would move something a site can read. The viewer resizes it over RFB
    /// straight afterwards anyway (002, 003) -- this is only what the framebuffer
    /// is before anyone looks.
    /// </summary>
    public const string Mode = "1280x720";

    // --render-cursor draws the pointer into the frame itself. Without it the
    // cursor is left to the client to draw from a cursor sprite, and a viewer that
    // does not draw one shows no pointer at all -- unusable for the handoff this
    // window exists for, since you cannot click what you cannot see.
    //
    // --websocket because the viewer is a page rather than a native client (see
    // Present). It changes what the port speaks: a browser can reach it, and a
    // raw VNC client no longer can.
    //
    // -o names the output, which cage never needed: it had one and wayvnc took
    // it. sway can be asked for a second at runtime, so the one being served has
    // to be said out loud.
    //
    // The session record is written from inside the session because only here can
    // the real values be observed: $PPID is the sway that started this script --
    // measured, not assumed, since sway's `exec` could plausibly have
    // double-forked and left init as the parent -- and WAYLAND_DISPLAY is the
    // display sway actually got rather than the one we hoped for.
    //
    // Chrome runs in the background and is waited on, rather than exec'd over
    // this shell as it was under cage. cage exited when its child did; sway does
    // not, and a compositor outliving its Chrome is precisely the stale state
    // that showed a viewer a black screen while every status read healthy. So the
    // script survives Chrome deliberately, to tell sway to go when it goes. That
    // costs the `$$` trick -- Chrome's pid now comes from `$!`, which names the
    // same process without needing to become it.
    public static string SessionScript => Assets.Read("Passenger.session.sh");

    /// <summary>
    /// Attaching the human's own IME to the session, or nothing at all.
    ///
    /// Without this a human handed the browser could not type Chinese into it:
    /// sway offers `text_input_v3` and `input_method_v2` since ticket 063, and
    /// nothing was there to *be* an input method. Chrome needed no argument --
    /// it already speaks the protocol -- so the whole fix is one D-Bus call.
    ///
    /// **The human's own fcitx5, not a second one.** The first version started a
    /// private instance on a private bus, against a copy of `~/.config/fcitx5`,
    /// and the owner asked the obvious question: why not reuse the one already
    /// running? fcitx5 exposes `OpenWaylandConnection` for exactly this -- one
    /// process serving several compositors -- so the session gets the real
    /// config and the real learned dictionary, live. It also disposes of
    /// everything the copy needed: no private bus to arrange, no config to keep
    /// in step, and no copy that was silently a symlink back to the original,
    /// which is what the first attempt turned out to be.
    ///
    /// Nothing to tear down, either: fcitx5 drops the connection when the
    /// display goes away.
    /// </summary>
    public static string ImeScript => Assets.Read("Passenger.ime.sh");

    /// <summary>
    /// The IME lines for a session, or a comment saying why there are none.
    ///
    /// No IME is an ordinary outcome rather than a failure: `PASSENGER_IME=none`
    /// asks for none, and a machine whose fcitx5 is not running answers the call
    /// with an error the log records. Pure, and separated from the PATH lookup,
    /// so both answers are testable wherever the suite happens to run.
    /// </summary>
    public static string ImeSection(string command, bool available) =>
        command is "none" or "" || !available
            ? "# no input method (PASSENGER_IME)"
            : ImeScript;

    /// <summary>
    /// The sway config, which exists to make sway behave like the kiosk cage was.
    ///
    /// No bar, no keybindings, no decorations: the human who takes over a handoff
    /// should find a browser, not a window manager they did not ask for, and a
    /// stray keystroke should not be able to reach a compositor command.
    ///
    /// **The absence of keybindings is the point, and it is guaranteed by two
    /// things.** sway has none compiled in -- every binding comes from a config
    /// -- and `-c` means the one the distribution ships is never read. So the
    /// compositor here composites and nothing else, and every key the human
    /// presses belongs to the browser. Adding a `bindsym` would quietly take one
    /// back, which is why a test asserts there are none.
    /// </summary>
    public static string SessionConfig => Assets.Read("Passenger.sway.conf");

    /// <summary>
    /// Chrome inside its own sway compositor, viewed over VNC on demand.
    ///
    /// The host compositor is not involved, so nothing here breaks when you switch
    /// compositors -- or when one of them rewrites the IPC a backend depended on.
    /// The IPC this one speaks is its own sway's, started here and pinned with the
    /// rest of the closure (ticket 063).
    /// </summary>
    public sealed class NestedBackend : IWindowBackend
    {
        public BackendName Name => BackendName.Nested;

        // swaymsg as well as sway: the session script uses it to bring the
        // compositor down when Chrome goes, and a sway without it would leave
        // one running behind a dead browser.
        public bool Available() => Which("sway") is not null
                                   && Which("swaymsg") is not null
                                   && Which("wayvnc") is not null;

        public void Prepare()
        {
        }

        /// <summary>
        /// What this session *is*, said to Chrome rather than hoped for.
        ///
        /// The session serves Wayland and nothing else: `WLR_BACKENDS=headless`,
        /// no DRM master, no X server. Chrome was never told, and on the machine
        /// this was written on it came up as a Wayland client anyway -- because
        /// the developer's `~/.config/chrome-flags.conf` happened to say
        /// `--ozone-platform-hint=auto`, which the distribution's wrapper splices
        /// into argv. On any host without that file Chrome would fall back to
        /// X11, which in here means Xwayland or, where the closure has none, a
        /// browser that never starts (ticket 061).
        ///
        /// Unconditional, and only in this backend. There is no X to fall back
        /// to inside the session, so nothing is being closed off that was
        /// reachable; `--visible` still hands the host's own desktop whatever it
        /// prefers. Chrome has accepted the flag since ozone shipped, and a
        /// Chrome older than that could not have run in here at all.
        /// </summary>
        private static readonly string[] Platform = ["--ozone-platform=wayland"];

        public LaunchPlan Plan(IReadOnlyList<string> argv)
        {
            Directory.CreateDirectory(Config.StateDir);
            // Claimed per session rather than fixed: a second session that reused
            // the port would lose the bind, leaving the *stale* wayvnc serving an
            // empty compositor to anyone who connected.
            int port = Sessions.FreePort();
            string ctl = Sessions.CtlSocket(port);
            // After argv[0], so the browser being launched is still the first
            // word and a reader of the generated script sees which one it is.
            IReadOnlyList<string> full = [argv[0], .. Platform, .. argv.Skip(1)];
            string quoted = string.Join(" ", full.Select(a => $"'{a}'"));
            string ime = Config.Settings.ImeCommand;
            string imeScript = ImeSection(ime, Which("dbus-send") is not null);

            File.WriteAllText(SessionSh, SessionScript
                .Replace("{state}", Config.StateDir)
                .Replace("{ime}", imeScript)
                .Replace("{ctl}", ctl)
                .Replace("{host}", Config.Settings.VncHost)
                .Replace("{port}", port.ToString())
                .Replace("{record}", Sessions.SessionFile)
                .Replace("{output}", Output)
                .Replace("{chrome}", quoted));
            File.SetUnixFileMode(SessionSh,
                UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute
                | UnixFileMode.GroupRead | UnixFileMode.GroupExecute
                | UnixFileMode.OtherRead | UnixFileMode.OtherExecute);
            // sway starts the session script from the config rather than taking
            // it as an argument the way `cage -- script` did. There is no way to
            // hand it one: the display name is not known until sway has picked it,
            // so the script has to be started from inside, which is exactly where
            // it needs to be to read WAYLAND_DISPLAY back out.
            File.WriteAllText(SessionConf, SessionConfig
                .Replace("{output}", Output)
                .Replace("{mode}", Mode)
                .Replace("{script}", SessionSh));

            // Headless wlroots still renders through the GPU render node, so WebGL
            // keeps reporting the real adapter.
            return new LaunchPlan
            {
                Argv = ["sway", "-c", SessionConf],
                Env = new Dictionary<string, string>
                {
                    ["WLR_BACKENDS"] = "headless",
                    ["WLR_LIBINPUT_NO_DEVICES"] = "1",
                },
            };
        }
    }

    /// <summary>No mechanism available; the window simply stays visible.</summary>
    public sealed class NoOpBackend : IWindowBackend
    {
        public BackendName Name => BackendName.None;

        public bool Available() => true;

        public void Prepare()
        {
        }

        public LaunchPlan Plan(IReadOnlyList<string> argv) => new() { Argv = argv };
    }

    private static IWindowBackend Build(BackendName name) => name switch
    {
        BackendName.Nested => new NestedBackend(),
        BackendName.None => new NoOpBackend(),
        _ => throw new ArgumentOutOfRangeException(nameof(name)),
    };

    private static readonly BackendName[] AutoOrder = [BackendName.Nested, BackendName.None];

    public static IWindowBackend Select()
    {
        string? forced = Environment.GetEnvironmentVariable("PASSENGER_WM");
        if (!string.IsNullOrEmpty(forced))
        {
            BackendName? name = EnumNames.ParseBackend(forced);
            if (name is null)
            {
                throw new WindowException(
                    ErrorCode.UnknownWindowBackend, $"unknown backend '{forced}'",
                    string.Join(", ", EnumNames.BackendNames));
            }

            return Build(name.Value);
        }

        foreach (BackendName name in AutoOrder)
        {
            IWindowBackend backend = Build(name);
            if (backend.Available())
            {
                return backend;
            }
        }

        return new NoOpBackend();
    }

    /// <summary>
    /// Where a program is on PATH, or null. `shutil.which`, which .NET has no
    /// equivalent of.
    /// </summary>
    public static string? Which(string program)
    {
        if (program.Contains('/'))
        {
            return File.Exists(program) && IsExecutable(program) ? program : null;
        }

        string path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (string dir in path.Split(':', StringSplitOptions.RemoveEmptyEntries))
        {
            string candidate = Path.Combine(dir, program);
            if (File.Exists(candidate) && IsExecutable(candidate))
            {
                return candidate;
            }
        }

        return null;
    }

    private static bool IsExecutable(string path)
    {
        try
        {
            UnixFileMode mode = File.GetUnixFileMode(path);
            return (mode & (UnixFileMode.UserExecute | UnixFileMode.GroupExecute
                            | UnixFileMode.OtherExecute)) != 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
}
