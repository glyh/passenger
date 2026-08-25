// Imperative shell: the environment boundary.
//
// Every PASSENGER_* variable is read exactly once, here, into a frozen record.
// No other module touches the environment (except Launch's backend override,
// which must be read before a backend exists to hold it).

namespace Passenger;

public sealed record Settings
{
    public required string StateDir { get; init; }
    public int CdpPort { get; init; } = 9222;
    public string ChromeBinary { get; init; } = "google-chrome-stable";
    public int HandoffTimeoutS { get; init; } = 300;

    /// <summary>
    /// How long to wait for an attach before treating the browser as stuck.
    /// Attaching initialises every open tab, so this is really a budget for the
    /// slowest one.
    /// </summary>
    public int AttachTimeoutS { get; init; } = 15;

    public string VncHost { get; init; } = "127.0.0.1";
    public int VncPort { get; init; } = 5900;

    /// <summary>
    /// The viewer asks for the framebuffer size it needs, so there is nothing to
    /// pin here. The scale it cannot ask for: unset means "match the host
    /// screen", and setting it overrides that.
    /// </summary>
    public double? VncScale { get; init; }

    public int NovncPort { get; init; } = 6080;

    /// <summary>
    /// Where noVNC's modules live. Set by the flake to a store path holding
    /// only the static files; unset means "look in the usual system places".
    /// </summary>
    public string? NovncDir { get; init; }

    /// <summary>
    /// The browser the viewer window is opened in, which is the host's, not the
    /// nested one -- though by default it is the same binary.
    /// </summary>
    public string? ViewerBrowser { get; init; }

    /// <summary>
    /// Whether the session asks the human's IME to serve it: `fcitx5`, or `none`.
    ///
    /// **Defaults to `none`, because it crashes Chrome** (ticket 067). Measured
    /// twice on fresh profiles, one variable apart: with no IME the browser ran
    /// out a full minute clean, and with the IME attached it segfaulted within a
    /// second. Attaching a separate fcitx5 instance by hand crashed it the same
    /// way, so this is about an input method being present at all rather than
    /// about reusing the human's one.
    ///
    /// The mechanism stays, off, because it is one D-Bus call and it demonstrably
    /// works as an input method -- typed into, by hand, before it was wired in.
    /// What is not understood is why Chrome dies, and shipping a browser that
    /// does not start is worse than shipping one that cannot compose.
    /// </summary>
    public string ImeCommand { get; init; } = "none";

    public PresenterName? Presenter { get; init; }
    public string? WebhookUrl { get; init; }

    public static Settings FromEnvironment()
    {
        string? Raw(string name)
        {
            string? value = Environment.GetEnvironmentVariable(name);
            return string.IsNullOrEmpty(value) ? null : value;
        }

        // The strings are coerced here rather than by a validating layer, and a
        // value that will not parse falls back to the default: this is start-up,
        // and a typo'd PASSENGER_PORT should not be the reason nothing runs.
        int Int(string name, int fallback, int low, int high) =>
            int.TryParse(Raw(name), out int parsed) && parsed >= low && parsed <= high
                ? parsed : fallback;

        var settings = new Settings
        {
            StateDir = Raw("PASSENGER_STATE") ?? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".local", "share", "passenger"),
            CdpPort = Int("PASSENGER_PORT", 9222, 1, 65535),
            ImeCommand = Raw("PASSENGER_IME") ?? "none",
            ChromeBinary = Raw("PASSENGER_CHROME") ?? "google-chrome-stable",
            HandoffTimeoutS = Int("PASSENGER_HANDOFF_TIMEOUT", 300, 1, int.MaxValue),
            AttachTimeoutS = Int("PASSENGER_ATTACH_TIMEOUT", 15, 1, int.MaxValue),
            VncHost = Raw("PASSENGER_VNC_HOST") ?? "127.0.0.1",
            VncPort = Int("PASSENGER_VNC_PORT", 5900, 1, 65535),
            VncScale = double.TryParse(Raw("PASSENGER_VNC_SCALE"), out double scale)
                       && scale > 0 ? scale : null,
            NovncPort = Int("PASSENGER_NOVNC_PORT", 6080, 1, 65535),
            NovncDir = Raw("PASSENGER_NOVNC"),
            ViewerBrowser = Raw("PASSENGER_VIEWER"),
            Presenter = Raw("PASSENGER_PRESENTER") is { } name
                ? EnumNames.ParsePresenter(name) : null,
            WebhookUrl = Raw("PASSENGER_WEBHOOK"),
        };
        return settings;
    }

    /// <summary>Where the Wayland sockets live, for talking to the nested session.</summary>
    public string RuntimeDir =>
        Environment.GetEnvironmentVariable("XDG_RUNTIME_DIR") is { Length: > 0 } dir
            ? dir
            : $"/run/user/{Syscall.Getuid()}";

    public string ProfileDir => Path.Combine(StateDir, "chrome-profile");

    /// <summary>
    /// A profile of its own for the window the browser is watched in.
    ///
    /// Separate from the user's everyday browser for two reasons. It keeps a
    /// takeover window out of their session entirely, and it is what makes
    /// the window ours to close: launched into an already-running Chrome, the
    /// process we started hands the window over and exits, leaving nothing to
    /// track or dismiss.
    /// </summary>
    public string ViewerProfile => Path.Combine(StateDir, "viewer-profile");

    public string ReportsDir => Path.Combine(StateDir, "reports");

    public string CdpUrl => $"http://127.0.0.1:{CdpPort}";

    /// <summary>
    /// The page, without the endpoint: that is per-session, so Present appends
    /// it from the live record rather than from settings.
    /// </summary>
    public string ViewerUrl => $"http://{VncHost}:{NovncPort}/";
}

/// <summary>
/// The one settings instance, read at start-up.
///
/// A mutable static rather than a readonly one so the test suite can point the
/// whole tool at a temporary state directory, which is what conftest.py does on
/// the Python side. Nothing else assigns it.
/// </summary>
public static class Config
{
    public static Settings Settings { get; set; } = Settings.FromEnvironment();

    // Aliases so call sites read as plain names rather than Config.Settings.X
    // everywhere. Properties rather than constants, because the tests replace
    // the settings object underneath them.
    public static string StateDir => Settings.StateDir;
    public static string ProfileDir => Settings.ProfileDir;
    public static string ReportsDir => Settings.ReportsDir;
    public static int CdpPort => Settings.CdpPort;
    public static string CdpUrl => Settings.CdpUrl;
    public static string ChromeBin => Settings.ChromeBinary;
    public static int HandoffTimeoutS => Settings.HandoffTimeoutS;
    public static int AttachTimeoutS => Settings.AttachTimeoutS;
}
