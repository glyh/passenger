// Imperative shell: at what density the nested browser renders.
//
// The *size* of the nested output is no longer decided here. The viewer asks for
// it: noVNC sends the RFB `SetDesktopSize` its window needs, wayvnc answers it
// through cage's wlr-output-management, and the framebuffer follows the window
// continuously -- including while it is being dragged to a new size. Everything
// this module used to do to guess that size went with it, along with the race it
// could never win: wayvnc advertises a resize to clients some time after
// wlr-randr returns, and a viewer connecting inside that gap kept the old shape.
//
// What a viewer cannot ask for is the *scale*, and scale is not cosmetic. It is
// what decides whether the nested Chrome treats a 1422x1730 output as 1422x1730
// CSS pixels of unreadably small page, or as 889x1081 at dpr 2 -- which is what
// an ordinary laptop reports, and what someone reading a captcha needs.
//
// Setting the scale leaves the framebuffer size alone, so unlike the old fitting
// it cannot disturb a connected viewer; a live session was watched through a
// scale change and back to confirm it.

using System.Diagnostics;
using System.Globalization;

namespace Passenger;

/// <summary>How many device pixels the nested Chrome draws per CSS pixel.</summary>
public sealed record Scale
{
    public required double Factor { get; init; }

    /// <summary>The bound pydantic held with `Field(gt=0)`.</summary>
    public Scale Validated() => Factor > 0
        ? this
        : throw new ArgumentException("scale factor must be above 0");
}

public static class Geometry
{
    private const string HeadlessPrefix = "HEADLESS";

    /// <summary>
    /// Run a tool and return its stdout, or "" if it could not run at all.
    ///
    /// The environment is layered over the current one rather than replacing it:
    /// passing a bare dictionary drops PATH, and the command then cannot be found
    /// even though it is installed.
    ///
    /// Failures are swallowed because every caller here is improving the picture,
    /// never keeping the session alive -- a missing tool should cost sharpness,
    /// not the browser.
    /// </summary>
    private static string Run(IReadOnlyDictionary<string, string>? env, params string[] args)
    {
        try
        {
            var start = new ProcessStartInfo(args[0])
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
            };
            foreach (string arg in args.Skip(1))
            {
                start.ArgumentList.Add(arg);
            }

            if (env is not null)
            {
                foreach ((string key, string value) in env)
                {
                    start.Environment[key] = value;
                }
            }

            using Process? process = Process.Start(start);
            if (process is null)
            {
                return "";
            }

            string output = process.StandardOutput.ReadToEnd();
            process.WaitForExit();
            return output;
        }
        catch (Exception)
        {
            return "";
        }
    }

    /// <summary>An explicit scale from the environment, which wins over the probe.</summary>
    public static Scale? Configured() =>
        Config.Settings.VncScale is { } factor
            ? new Scale { Factor = factor }.Validated()
            : null;

    /// <summary>
    /// The scale the host screen runs, which the viewer's window inherits.
    ///
    /// wlr-randr first and core `wl_output` second, because the two answer with
    /// different precision: wl_output carries an integer buffer scale, so a screen
    /// at 1.6 reads as 2, while wlr-randr reports the compositor's real fractional
    /// value. The integer is a usable fallback -- Chrome rounds the scale up to an
    /// integer anyway -- but it is not the same picture.
    /// </summary>
    public static Scale? Host()
    {
        foreach (string line in Run(null, "wlr-randr").Split('\n'))
        {
            if (line.TrimStart().StartsWith("Scale:", StringComparison.Ordinal))
            {
                double? value = Number(line.Split("Scale:")[1]);
                if (value is not null)
                {
                    return new Scale { Factor = value.Value }.Validated();
                }
            }
        }

        return WlOutputScale();
    }

    /// <summary>The first output's integer buffer scale, from core wl_output.</summary>
    private static Scale? WlOutputScale()
    {
        if (Launch.Which("wayland-info") is null)
        {
            return null;
        }

        foreach (string line in FirstBlock(Run(null, "wayland-info")).Split('\n'))
        {
            // Not StartsWith: scale shares a line with the position, as
            // `x: 0, y: 0, scale: 2,`.
            if (line.Contains("scale:", StringComparison.Ordinal))
            {
                double? value = Number(line.Split("scale:")[1]);
                if (value is not null)
                {
                    return new Scale { Factor = value.Value }.Validated();
                }
            }
        }

        return null;
    }

    /// <summary>
    /// The first wl_output stanza, from its header to the next interface.
    ///
    /// Scoped to one output because a second monitor further down the dump
    /// describes a screen the viewer is not on.
    /// </summary>
    public static string FirstBlock(string report)
    {
        string[] lines = report.Split('\n');
        int start = Array.FindIndex(lines, l => l.Contains("wl_output", StringComparison.Ordinal));
        if (start < 0)
        {
            return "";
        }

        int end = Array.FindIndex(lines, start + 1,
            l => l.StartsWith("interface:", StringComparison.Ordinal));
        if (end < 0)
        {
            end = lines.Length;
        }

        return string.Join("\n", lines[start..end]);
    }

    /// <summary>Leading number of a field like `1.601562` or `2,`.</summary>
    public static double? Number(string text)
    {
        string digits = "";
        foreach (char ch in text.Trim())
        {
            if (char.IsAsciiDigit(ch) || (ch == '.' && !digits.Contains('.')))
            {
                digits += ch;
            }
            else if (digits.Length > 0)
            {
                break;
            }
        }

        return digits.Length > 0
            ? double.Parse(digits, CultureInfo.InvariantCulture)
            : null;
    }

    /// <summary>The configured scale, or the host screen's, or nothing to say.</summary>
    public static Scale? Select() => Configured() ?? Host();

    private static string? OutputName(IReadOnlyDictionary<string, string> env)
    {
        foreach (string line in Run(env, "wlr-randr").Split('\n'))
        {
            if (line.StartsWith(HeadlessPrefix, StringComparison.Ordinal))
            {
                return line.Split(' ', StringSplitOptions.RemoveEmptyEntries)[0];
            }
        }

        return null;
    }

    /// <summary>
    /// Set the nested output's scale, or null if it could not be set.
    ///
    /// Best effort by design: a failure here costs picture quality, never the
    /// session, so it is reported rather than raised. Reported honestly, though --
    /// announcing a scale wlr-randr refused would be the same silent lie the old
    /// resize told.
    /// </summary>
    public static string? Apply(string display, Scale scale)
    {
        if (Launch.Which("wlr-randr") is null)
        {
            return null;
        }

        var env = new Dictionary<string, string>
        {
            ["WAYLAND_DISPLAY"] = display,
            ["XDG_RUNTIME_DIR"] = Config.Settings.RuntimeDir,
        };
        string? name = OutputName(env);
        if (name is null)
        {
            return null;
        }

        string factor = scale.Factor.ToString("G", CultureInfo.InvariantCulture);
        try
        {
            var start = new ProcessStartInfo("wlr-randr")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
            };
            foreach (string arg in new[] { "--output", name, "--scale", factor })
            {
                start.ArgumentList.Add(arg);
            }

            foreach ((string key, string value) in env)
            {
                start.Environment[key] = value;
            }

            using Process? process = Process.Start(start);
            if (process is null)
            {
                return null;
            }

            process.WaitForExit();
            return process.ExitCode != 0 ? null : $"scale {factor}";
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>Give the nested output the density of the screen it will be seen on.</summary>
    public static string? Fit(string display)
    {
        Scale? scale = Select();
        return scale is null ? null : Apply(display, scale);
    }
}
