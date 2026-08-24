// Imperative shell: serving the page a human takes the browser over in.
//
// Two roots and nothing else: the viewer page that ships with this assembly, and
// noVNC's own modules, which are read from wherever the packaging put them. A
// general-purpose static server over one merged directory would have been less
// code, but it would also have to be pointed at a directory containing both --
// and building that means copying noVNC out of the store at runtime.
//
// The process is detached and outlives the command that started it, the same way
// cage and wayvnc do, because `show` returns while the window stays open.

using System.Diagnostics;
using System.Net;
using System.Reflection;
using System.Text;

namespace Passenger;

public static class Webserve
{
    /// <summary>
    /// The viewer page, out of the assembly rather than off disk.
    ///
    /// The Python side read it from a path beside the module. Embedded means a
    /// single-file publish still serves it, and that there is no path to get
    /// wrong when the tool is installed somewhere other than a source tree.
    /// </summary>
    public static string Page => ReadResource("Passenger.viewer.html");

    /// <summary>
    /// Lived on `PicturesJs` until ticket 048 deleted it, which left the viewer
    /// page as the assembly's one embedded resource and this as its one reader.
    /// </summary>
    private static string ReadResource(string name)
    {
        using Stream? stream = Assembly.GetExecutingAssembly()
            .GetManifestResourceStream(name)
            ?? throw new InvalidOperationException(
                $"{name} is missing from the assembly");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    private static readonly string[] NovncCandidates =
    [
        "/usr/share/webapps/novnc",
        "/usr/share/novnc",
        "/usr/local/share/novnc",
    ];

    /// <summary>
    /// Where noVNC's modules live, or null if this machine has none.
    ///
    /// PASSENGER_NOVNC first, which is what the flake sets to a store path
    /// holding just the static files; the well-known distribution paths after it,
    /// so a system-installed noVNC works without configuration.
    /// </summary>
    public static string? NovncRoot()
    {
        if (Config.Settings.NovncDir is { } configured)
        {
            return File.Exists(Path.Combine(configured, "core", "rfb.js"))
                ? configured : null;
        }

        foreach (string candidate in NovncCandidates)
        {
            if (File.Exists(Path.Combine(candidate, "core", "rfb.js")))
            {
                return candidate;
            }
        }

        return null;
    }

    /// <summary>
    /// Map a request to a file, or to nothing at all.
    ///
    /// Deliberately not a general static server, which would serve the whole
    /// working directory: this process exists to hand out two things, and a
    /// static server that will read any file it can reach is not something to
    /// leave listening on a socket, however local.
    ///
    /// Pure, and separated from the serving so the containment check is testable
    /// without binding a port. That check is the security-relevant half: `..` in
    /// a request must not walk out of the noVNC tree.
    /// </summary>
    public static string? TranslatePath(string path, string root)
    {
        string clean = path.Split('?')[0].Split('#')[0];
        if (clean is "/" or "/index.html")
        {
            return "";  // the empty string means "the embedded viewer page"
        }

        const string prefix = "/novnc/";
        if (clean.StartsWith(prefix, StringComparison.Ordinal))
        {
            string full = Path.GetFullPath(Path.Combine(root, clean[prefix.Length..]));
            string within = Path.GetFullPath(root);
            if (full.StartsWith(within + Path.DirectorySeparatorChar, StringComparison.Ordinal)
                || full == within)
            {
                return full;
            }
        }

        return null;
    }

    private static readonly Dictionary<string, string> ContentTypes = new()
    {
        [".html"] = "text/html; charset=utf-8",
        [".js"] = "text/javascript; charset=utf-8",
        [".mjs"] = "text/javascript; charset=utf-8",
        [".css"] = "text/css; charset=utf-8",
        [".json"] = "application/json",
        [".svg"] = "image/svg+xml",
        [".png"] = "image/png",
        [".ico"] = "image/x-icon",
        [".woff"] = "font/woff",
        [".woff2"] = "font/woff2",
    };

    public static void Serve(int port, string root)
    {
        using var listener = new HttpListener();
        listener.Prefixes.Add($"http://{Config.Settings.VncHost}:{port}/");
        listener.Start();
        while (true)
        {
            HttpListenerContext context = listener.GetContext();
            // One thread per request, matching ThreadingHTTPServer: the viewer
            // pulls a few dozen module files at once on first load, and serving
            // them one at a time is visible as a slow window.
            ThreadPool.QueueUserWorkItem(_ => Answer(context, root));
        }
    }

    private static void Answer(HttpListenerContext context, string root)
    {
        try
        {
            string? target = TranslatePath(context.Request.Url?.AbsolutePath ?? "/", root);
            if (target is null)
            {
                context.Response.StatusCode = 404;
                context.Response.Close();
                return;
            }

            byte[] body;
            if (target.Length == 0)
            {
                body = Encoding.UTF8.GetBytes(Page);
                context.Response.ContentType = ContentTypes[".html"];
            }
            else if (File.Exists(target))
            {
                body = File.ReadAllBytes(target);
                context.Response.ContentType = ContentTypes.GetValueOrDefault(
                    Path.GetExtension(target), "application/octet-stream");
            }
            else
            {
                context.Response.StatusCode = 404;
                context.Response.Close();
                return;
            }

            context.Response.ContentLength64 = body.Length;
            context.Response.OutputStream.Write(body);
            context.Response.Close();
        }
        catch (Exception)
        {
            // Quiet: this runs detached, and its stdout goes nowhere useful. A
            // viewer that reloads mid-response is the ordinary case here.
            try
            {
                context.Response.Abort();
            }
            catch (Exception)
            {
                // Nothing left to do about it.
            }
        }
    }

    /// <summary>Is something already serving on that port?</summary>
    public static bool Listening(int port) =>
        Sessions.IsListening(Config.Settings.VncHost, port);

    /// <summary>
    /// Start the server unless it is already up. False if it cannot be.
    ///
    /// Started as a detached child rather than a thread because the CLI process
    /// exits as soon as `show` has returned, and the window it opened needs the
    /// page to keep being served for as long as it is open.
    /// </summary>
    public static bool Ensure(int port)
    {
        if (Listening(port))
        {
            return true;
        }

        if (NovncRoot() is null)
        {
            return false;
        }

        try
        {
            // Re-runs this same executable with a private argument, which is the
            // .NET shape of `python -m passenger.webserve`. Whichever entry point
            // is running -- CLI or MCP server -- can serve the page.
            var start = new ProcessStartInfo(Environment.ProcessPath
                                             ?? "passenger")
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            foreach (string arg in ReExecArgs(port))
            {
                start.ArgumentList.Add(arg);
            }

            using Process? spawned = Process.Start(start);
            if (spawned is null)
            {
                return false;
            }

            spawned.BeginOutputReadLine();
            spawned.BeginErrorReadLine();
        }
        catch (Exception)
        {
            return false;
        }

        for (int i = 0; i < 20; i++)
        {
            if (Listening(port))
            {
                return true;
            }

            Thread.Sleep(100);
        }

        return false;
    }

    /// <summary>
    /// The private re-exec argument. Not a public verb: nothing but
    /// <see cref="Ensure"/> should ask for it, and it takes no other arguments.
    /// </summary>
    public const string ServeFlag = "--serve-viewer";

    private static string[] ReExecArgs(int port)
    {
        // A framework-dependent build runs as `dotnet Passenger.Cli.dll`, so the
        // assembly path has to be passed back through; a published apphost is
        // its own executable and takes the flag directly.
        string? host = Environment.ProcessPath;
        string assembly = Environment.GetCommandLineArgs()[0];
        return host is not null && Path.GetFileNameWithoutExtension(host) == "dotnet"
            ? [assembly, ServeFlag, port.ToString()]
            : [ServeFlag, port.ToString()];
    }

    /// <summary>
    /// The re-exec entry point, called by both frontends before they parse
    /// anything else. Returns true when it handled the arguments and served.
    /// </summary>
    public static bool ServeIfAsked(string[] args)
    {
        if (args.Length < 1 || args[0] != ServeFlag)
        {
            return false;
        }

        string? root = NovncRoot();
        if (root is null)
        {
            Console.Error.WriteLine("no noVNC installation found; set PASSENGER_NOVNC");
            Environment.Exit(1);
        }

        int port = args.Length > 1 && int.TryParse(args[1], out int parsed)
            ? parsed : Config.Settings.NovncPort;
        Serve(port, root!);
        return true;
    }
}
