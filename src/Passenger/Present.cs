// Imperative shell: putting the hidden browser in front of a human.
//
// Separate from how Chrome is launched. wayvnc is always running inside the
// nested compositor, serving the session over a websocket; presenting just means
// giving someone a way to look at it, and that differs by where the tool is
// deployed:
//
//   local  open the viewer page in a chromeless window of the host's browser
//   web    hand back the URL to open wherever the human actually is -- the only
//          option that works from a container with no display of its own
//   none   nothing can show it; say so rather than pretending
//
// There is no VNC client here any more. The viewer is a page served to the host's
// own browser, which is both lighter than every native client that would do --
// 1.8 MB of noVNC against 1.2 GiB for the lightest native one that works -- and
// the only one of them that gets the size right by itself: it asks for the
// framebuffer its window needs and keeps asking as the window changes. The native
// client this replaced did the opposite, stretching whatever it was sent to fill
// its window and freezing that aspect at connect time, which is why the picture
// used to arrive squashed inside black bars.
//
// Opening it in app mode is what makes it read as a window rather than a browser
// tab: no tab strip, no address bar, and the page itself is the screen, edge to
// edge.
//
// Every URL reported from here has been fetched before it was reported. This is
// a handoff to a *human*, and the cost of handing over a broken page is that the
// person stares at an error and reports the tool as broken -- which is exactly
// what ticket 058 was. `Webserve.Ensure` does the fetching, so the check is one
// request against a local server on a call that already blocks. Note the limit:
// whether the page *renders* stays the human's judgement; whether it was
// *served* is a fact this tool can have, and now does.

using System.Diagnostics;

namespace Passenger;

public interface IPresenter
{
    PresenterName Name { get; }

    /// <summary>
    /// Whether <see cref="Presented"/> is a real observation or a standing guess.
    /// Only a presenter that can see its own window may be waited on: the human
    /// closing the viewer is the one completion signal this tool does not have
    /// to infer, and a presenter that always answers false would report it the
    /// instant the wait began (ticket 018).
    /// </summary>
    bool ObservesPresence { get; }

    bool Available();

    Task<string> PresentAsync();

    void Dismiss();

    bool Presented();
}

public static class Present
{
    // Chrome first because it is already this tool's dependency, then the common
    // Chromium builds: app mode is a Chromium feature, and a browser without it
    // would open a tab with a URL bar around the screen.
    public static readonly string[] Browsers =
    [
        "google-chrome-stable", "chromium", "chromium-browser",
        "brave-browser", "microsoft-edge-stable",
    ];

    private const int OpenPolls = 20;
    private const int PollIntervalMs = 250;

    /// <summary>
    /// Where the *live* session is listening.
    ///
    /// Read from the session record rather than from settings, because the port a
    /// session ends up on is claimed when it starts. Pointing a viewer at the
    /// configured port instead is how a viewer ends up attached to a previous,
    /// dead session and shows nothing but black.
    /// </summary>
    public static (string Host, int Port) Endpoint()
    {
        NestedSession? live = Sessions.Live();
        return live is null
            ? (Config.Settings.VncHost, Config.Settings.VncPort)
            : (live.VncHost, live.VncPort);
    }

    /// <summary>The viewer page, told which session to connect to.</summary>
    public static string PageUrl()
    {
        (string host, int port) = Endpoint();
        return $"{Config.Settings.ViewerUrl}?ws={host}:{port}";
    }

    /// <summary>
    /// Make the nested session fit to be looked at, and say what changed.
    ///
    /// Two things a human needs that a hidden browser does not. The output takes
    /// the host screen's density -- only the density: the size belongs to the
    /// viewer, which asks for it over RFB as soon as it connects and again
    /// whenever its window changes. And Chrome comes out of the fullscreen cage
    /// put it in, which is what hid its address bar and back button from the
    /// person being asked to use them.
    ///
    /// Done here rather than only at startup so that a session started before
    /// this existed, or one somehow re-fullscreened, is still handed over with
    /// its controls.
    /// </summary>
    private static async Task<string> PreparedAsync(NestedSession? live)
    {
        if (live is null)
        {
            return "";
        }

        await Browser.UnfullscreenAsync();
        string? change = Geometry.Fit(live.WaylandDisplay);
        return change is null ? "" : $", {change}";
    }

    /// <summary>Open the viewer page in a chromeless window on this machine.</summary>
    public sealed class WindowPresenter : IPresenter
    {
        public PresenterName Name => PresenterName.Local;

        public bool ObservesPresence => true;

        public string? Browser()
        {
            IEnumerable<string> candidates = Config.Settings.ViewerBrowser is { } chosen
                ? [chosen] : Browsers;
            return candidates.FirstOrDefault(b => Launch.Which(b) is not null);
        }

        public bool Available() => Browser() is not null && Webserve.NovncRoot() is not null;

        /// <summary>
        /// Is *our* window open?
        ///
        /// Tracked by the pid we spawned, which is only meaningful because the
        /// window runs on a profile of its own -- see Settings.ViewerProfile.
        /// </summary>
        public bool Presented() => Sessions.ViewerPid() is not null;

        public async Task<string> PresentAsync()
        {
            NestedSession? live = Sessions.Live();
            if (Presented())
            {
                return $"viewer already open{await PreparedAsync(live)}";
            }

            string? browser = Browser();
            if (browser is null)
            {
                throw new WindowException(ErrorCode.NoPresenter, "no browser to open",
                                          ManualHint());
            }

            // Refused rather than shown: with no live session there is nothing
            // behind the port, and a viewer opened onto it shows an empty
            // rectangle that looks exactly like a broken stack.
            if (live is null)
            {
                throw new WindowException(
                    ErrorCode.NoPresenter, "no live browser session",
                    "the daemon starts on demand, so this is one that failed or "
                    + "died; `browserStatus` says which");
            }

            if (!Webserve.Ensure(Config.Settings.NovncPort))
            {
                throw new WindowException(ErrorCode.NoPresenter, "cannot serve the viewer",
                                          "no noVNC found; set PASSENGER_NOVNC");
            }

            string prepared = await PreparedAsync(live);
            Open(browser);
            return $"opened {browser} on {PageUrl()}{prepared}";
        }

        /// <summary>Start the window and wait for it to be up, or say it never was.</summary>
        private void Open(string browser)
        {
            string[] args =
            [
                $"--app={PageUrl()}",
                $"--user-data-dir={Config.Settings.ViewerProfile}",
                "--no-first-run", "--no-default-browser-check",
                "--class=passenger-viewer",
            ];
            var start = new ProcessStartInfo(browser)
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            foreach (string arg in args)
            {
                start.ArgumentList.Add(arg);
            }

            using Process? spawned = Process.Start(start);
            if (spawned is null)
            {
                throw new WindowException(ErrorCode.NoPresenter, "viewer window did not open",
                                          $"{browser} {string.Join(" ", args)}");
            }

            spawned.BeginOutputReadLine();
            spawned.BeginErrorReadLine();
            Sessions.RecordViewer(spawned.Id);
            for (int i = 0; i < OpenPolls; i++)
            {
                Thread.Sleep(PollIntervalMs);
                if (Presented())
                {
                    return;
                }
            }

            Sessions.ClearViewer();
            throw new WindowException(ErrorCode.NoPresenter, "viewer window did not open",
                                      $"{browser} {string.Join(" ", args)}");
        }

        /// <summary>
        /// Close only the window this tool opened.
        ///
        /// The old `pkill -x` swept up every VNC client on the machine, including
        /// remote desktops that had nothing to do with this browser.
        /// </summary>
        public void Dismiss()
        {
            if (Sessions.ViewerPid() is { } pid)
            {
                Syscall.Kill(pid, Syscall.Sigterm);
            }

            Sessions.ClearViewer();
        }

        private static string ManualHint() => $"open {PageUrl()} in any browser";
    }

    /// <summary>
    /// Hand back the URL for a human to open wherever they are.
    ///
    /// Whether anyone actually opened it is unknowable from here, so
    /// <see cref="Presented"/> stays false and <see cref="Dismiss"/> does nothing
    /// -- better than inventing a state we cannot observe.
    /// </summary>
    public sealed class LinkPresenter : IPresenter
    {
        public PresenterName Name => PresenterName.Web;

        public bool ObservesPresence => false;

        /// <summary>
        /// Only if the page can actually be served.
        ///
        /// Handing back a URL that answers nothing would be the same silent lie as
        /// launching a visible window and calling it hidden.
        /// </summary>
        public bool Available() => Webserve.NovncRoot() is not null;

        public bool Presented() => false;

        public async Task<string> PresentAsync()
        {
            NestedSession? live = Sessions.Live();
            if (!Webserve.Ensure(Config.Settings.NovncPort))
            {
                throw new WindowException(ErrorCode.NoPresenter, "cannot serve the viewer",
                                          "no noVNC found; set PASSENGER_NOVNC");
            }

            string prepared = await PreparedAsync(live);
            return $"open {PageUrl()} to take over the browser{prepared}";
        }

        public void Dismiss()
        {
        }
    }

    public sealed class NullPresenter : IPresenter
    {
        public PresenterName Name => PresenterName.None;

        public bool ObservesPresence => false;

        public bool Available() => true;

        public bool Presented() => false;

        /// <summary>
        /// Say what is actually available rather than just refusing.
        ///
        /// wayvnc is listening whenever the nested compositor is up, so a browser
        /// pointed at any noVNC installation can still reach it -- from another
        /// machine, or a phone. It speaks websocket rather than raw RFB, though,
        /// so a native VNC client is not the fallback it used to be.
        /// </summary>
        public Task<string> PresentAsync()
        {
            (string host, int port) = Endpoint();
            return Task.FromResult(
                "no viewer: nothing here can serve the noVNC page. wayvnc is "
                + $"listening on ws://{host}:{port} -- point a noVNC at it");
        }

        public void Dismiss()
        {
        }
    }

    private static IPresenter Build(PresenterName name) => name switch
    {
        PresenterName.Local => new WindowPresenter(),
        PresenterName.Web => new LinkPresenter(),
        PresenterName.None => new NullPresenter(),
        _ => throw new ArgumentOutOfRangeException(nameof(name)),
    };

    /// <summary>
    /// Explicit choice wins; otherwise the first mechanism that really exists.
    ///
    /// Each candidate is asked whether it is available, including the link one --
    /// an unconditional fallback would hand back a URL with nothing serving it,
    /// which is a worse answer than admitting there is no viewer.
    /// </summary>
    public static IPresenter Select()
    {
        if (Config.Settings.Presenter is { } chosen)
        {
            return Build(chosen);
        }

        foreach (IPresenter candidate in new IPresenter[]
                 { new WindowPresenter(), new LinkPresenter() })
        {
            if (candidate.Available())
            {
                return candidate;
            }
        }

        return new NullPresenter();
    }
}
