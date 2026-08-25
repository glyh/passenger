// What the nested backend writes before anything starts.
//
// `Plan` is the one part of the launch path that can be checked without a
// compositor: it is a pure-ish function from the Chrome argv to two generated
// files and an argv, and everything it gets wrong is invisible until a real
// session comes up wrong. Ticket 063 moved it from cage to sway, which split
// what used to be one file into a config and a script that have to agree with
// each other.

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
    public void TheImeGetsItsOwnBusAndItsOwnCopyOfTheConfig()
    {
        string section = Launch.ImeSection("fcitx5", available: true);

        // Its own bus, because the human's desktop almost certainly has an
        // fcitx5 holding org.fcitx.Fcitx5 already, and two on one bus fight.
        Assert.Contains("dbus-run-session -- fcitx5", section);
        // Its own config, copied from the host's: the dictionaries and layouts
        // come along, and the running desktop's profile is never written to.
        Assert.Contains("XDG_CONFIG_HOME=", section);
        Assert.Contains("$HOME/.config/fcitx5", section);
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
    public void TheImeIsTakenDownWithChrome()
    {
        (_, _, string script) = Planned();

        // A daemon left behind would outlive the session that wanted it. It is
        // also a Wayland client, so the compositor's exit would end it anyway --
        // this is the belt to that pair of braces.
        Assert.Contains("kill \"$ime_pid\"", script);
    }

    [Fact]
    public void TheScriptIsExecutable()
    {
        Planned();

        UnixFileMode mode = File.GetUnixFileMode(Launch.SessionSh);
        Assert.True(mode.HasFlag(UnixFileMode.UserExecute));
    }
}
