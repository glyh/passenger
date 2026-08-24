// Reading a scale out of two tools' output. Pure: recorded text, nothing spawned.
//
// Scale is not cosmetic (ticket 002/003): it decides whether the nested Chrome
// treats a 1422x1730 output as that many CSS pixels of unreadably small page, or
// as 889x1081 at dpr 2 -- which is what an ordinary laptop reports, and what
// someone reading a captcha needs. These two parsers are the whole of how it is
// discovered, and both read fields out of human-facing output.

using Passenger;
using Xunit;

namespace Passenger.Tests;

public class GeometryTests
{
    [Fact]
    public void AFractionalScaleIsReadWhole() =>
        Assert.Equal(1.601562, Geometry.Number(" 1.601562"));

    [Fact]
    public void ATrailingCommaIsNotPartOfTheNumber()
    {
        // wayland-info writes `x: 0, y: 0, scale: 2,` -- the field is mid-line
        // and comma-terminated.
        Assert.Equal(2.0, Geometry.Number(" 2,"));
    }

    [Fact]
    public void OnlyTheFirstNumberIsTaken() =>
        Assert.Equal(1.5, Geometry.Number("1.5 (2.0 preferred)"));

    [Fact]
    public void ASecondDotEndsTheNumberRatherThanCorruptingIt()
    {
        // A version-like string must not parse as a nonsense double.
        Assert.Equal(1.6, Geometry.Number("1.6.2"));
    }

    [Fact]
    public void AFieldWithNoNumberIsNothingToSay() =>
        Assert.Null(Geometry.Number("  auto"));

    [Fact]
    public void OnlyTheFirstOutputIsRead()
    {
        // Scoped to one output because a second monitor further down the dump
        // describes a screen the viewer is not on.
        const string report = """
            interface: 'wl_output', version: 4, name: 12
                x: 0, y: 0, scale: 2,
                make: 'Acme'
            interface: 'wl_seat', version: 9, name: 13
                x: 0, y: 0, scale: 3,
            """;
        string first = Geometry.FirstBlock(report);
        Assert.Contains("scale: 2,", first, StringComparison.Ordinal);
        Assert.DoesNotContain("scale: 3,", first, StringComparison.Ordinal);
    }

    [Fact]
    public void ADumpWithNoOutputIsEmptyRatherThanTheWholeThing()
    {
        // Returning everything would let the next `scale:` on any interface be
        // read as the screen's.
        Assert.Equal("", Geometry.FirstBlock("interface: 'wl_seat', version: 9"));
    }

    [Fact]
    public void AConfiguredScaleWinsOverTheProbe()
    {
        // The environment overrides what the host screen reports, which is the
        // only way to set it for a headless deployment with no screen to read.
        Settings restore = Config.Settings;
        try
        {
            Config.Settings = restore with { VncScale = 1.25 };
            Assert.Equal(1.25, Geometry.Configured()!.Factor);
        }
        finally
        {
            Config.Settings = restore;
        }
    }

    [Fact]
    public void NoConfiguredScaleMeansAskTheHost() => Assert.Null(
        (Config.Settings with { VncScale = null }).VncScale is { } f
            ? new Scale { Factor = f } : null);

    [Fact]
    public void AScaleOfZeroCannotExist()
    {
        // The bound pydantic held with `Field(gt=0)`: a zero or negative scale
        // is not a smaller picture, it is an unrenderable one.
        Assert.Throws<ArgumentException>(() => new Scale { Factor = 0 }.Validated());
        Assert.Throws<ArgumentException>(() => new Scale { Factor = -1 }.Validated());
    }
}
