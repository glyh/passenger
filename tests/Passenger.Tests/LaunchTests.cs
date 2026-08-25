// What the nested backend writes before anything starts.
//
// `Plan` is the one part of the launch path that can be checked without a
// compositor: it is a pure-ish function from the Chrome argv to two generated
// files and an argv, and everything it gets wrong is invisible until a real
// session comes up wrong. Ticket 063 moved it from cage to sway, which split
// what used to be one file into a config and a script that have to agree with
// each other.

using System.Text.RegularExpressions;
using Passenger;
using Xunit;

namespace Passenger.Tests;

public class LaunchTests
{
    private static (LaunchPlan Plan, string Config, string Script) Planned()
    {
        LaunchPlan plan = new Launch.NestedBackend().Plan(["chrome", "about:blank"]);
        return (plan, File.ReadAllText(Launch.SessionConf), File.ReadAllText(Launch.SessionSh));
    }

    [Fact]
    public void SwayIsStartedOnTheGeneratedConfig()
    {
        (LaunchPlan plan, string config, _) = Planned();

        Assert.Equal(["sway", "-c", Launch.SessionConf], plan.Argv);
        // The script cannot be passed as an argument the way `cage -- script`
        // took it, so the config has to be the thing that starts it.
        Assert.Contains($"exec {Launch.SessionSh}", config);
    }

    [Fact]
    public void TheConfigAndTheScriptNameTheSameOutput()
    {
        (_, string config, string script) = Planned();

        // Two files now have an opinion about which output exists, and wayvnc
        // serving one that sway did not create is a black screen with everything
        // reporting healthy -- the exact failure this project started from.
        Assert.Contains($"output {Launch.Output} resolution {Launch.Mode}", config);
        Assert.Contains($"-o {Launch.Output}", script);
    }

    [Fact]
    public void TheCompositorIsToldToGoWhenChromeDoes()
    {
        (_, _, string script) = Planned();

        // cage exited with its child and sway does not, so this is the line that
        // keeps a dead Chrome from leaving a live compositor holding the port.
        Assert.Contains("wait \"$chrome_pid\"", script);
        Assert.Contains("swaymsg exit", script);
    }

    [Fact]
    public void TheCompositorBindsNoKeys()
    {
        (_, string config, _) = Planned();

        // sway is here to composite and for nothing else: every key the human
        // presses in a handoff belongs to the browser. sway has no bindings
        // compiled in and `-c` keeps the distribution's config out, so the only
        // way one arrives is someone adding it here.
        // Directives only: a comment is free to name what it promises not to do,
        // and the first version of this test caught the comment saying so.
        IEnumerable<string> directives = config
            .Split('\n')
            .Select(line => line.Trim())
            .Where(line => line.Length > 0 && !line.StartsWith('#'));

        foreach (string line in directives)
        {
            foreach (string verb in new[] { "bindsym", "bindcode", "bindswitch",
                                            "bindgesture", "floating_modifier" })
            {
                Assert.DoesNotContain(verb, line, StringComparison.Ordinal);
            }
        }
    }

    [Fact]
    public void ChromesArgvIsQuotedIntoTheScript()
    {
        (_, _, string script) = Planned();

        // A URL with a shell metacharacter in it is an ordinary URL.
        Assert.Contains("'chrome' 'about:blank' &", script);
    }

    [Fact]
    public void TheImeIsTheHumansOwn()
    {
        string section = Launch.ImeSection("fcitx5", available: true);

        // Not a second instance: the fcitx5 already running for the human's
        // desktop is asked to serve this display as well, so the session gets
        // the real config and the real learned dictionary rather than a copy.
        Assert.Contains("OpenWaylandConnection", section);
        Assert.Contains("$WAYLAND_DISPLAY", section);
        Assert.DoesNotContain("dbus-run-session", section);
        Assert.DoesNotContain("XDG_CONFIG_HOME", section);
    }

    [Fact]
    public void NoImeIsAnOrdinaryOutcome()
    {
        // Asked for none, and none to be had: both are a session that simply
        // cannot compose, which is what every session was before ticket 066.
        Assert.DoesNotContain("dbus-run-session", Launch.ImeSection("none", available: true));
        Assert.DoesNotContain("dbus-run-session", Launch.ImeSection("fcitx5", available: false));
    }

    [Fact]
    public void NoPlaceholderSurvivesIntoWhatIsWritten()
    {
        (_, string config, string script) = Planned();

        // `{state}` once outlived its only user and reached the disk in the
        // script's very first line -- a redirect into a directory named
        // "{state}", which kills the shell before it can say so. The session
        // came up with a compositor, no browser, and no log to explain it.
        foreach (string written in new[] { config, script })
        {
            Match left = Regex.Match(written, @"\{[a-z][a-z0-9_]*\}");
            Assert.False(left.Success, $"placeholder {left.Value} was never substituted");
        }
    }

    [Fact]
    public void TheSessionKeepsALog()
    {
        (_, _, string script) = Planned();

        // Everything the session said about itself used to go to /dev/null,
        // which is how a wayvnc that could not bind and a compositor that
        // refused to exit both passed for a healthy session.
        Assert.Contains("session.log", script);
        Assert.Contains("swaymsg exit || echo", script);
    }

    [Fact]
    public void TheScriptIsExecutable()
    {
        Planned();

        UnixFileMode mode = File.GetUnixFileMode(Launch.SessionSh);
        Assert.True(mode.HasFlag(UnixFileMode.UserExecute));
    }
}
