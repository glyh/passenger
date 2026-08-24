// Liveness classification. Pure: a fixture PageProbe, no browser.
//
// `TheModeCanNoLongerChangeTheVerdict` lived here and cannot be written any
// more: ticket 021 took `word_count` off `PageProbe`, so the number the
// extraction mode used to reach a verdict through is not in the record at all.
// That guarantee is now structural rather than tested.
//
// `Classify` took the signature table as an argument until ticket 019, filled
// from a registry that could add learned rules to it. There is one table now and
// it is read directly, so these calls pass a probe and nothing else.

using Passenger;
using Xunit;

namespace Passenger.Tests;

public class DetectTests
{
    private static PageProbe Probe(
        string title = "珠海长隆海洋王国 - 小红书搜索",
        string url = "https://www.xiaohongshu.com/search_result?keyword=x") =>
        new() { Url = url, Title = title };

    [Fact]
    public void ARenderedCjkListingIsNotBlocked()
    {
        // Ticket 008: this page counted 66 words, under the default 80, so a
        // fully rendered listing with nothing in its way was called blocked and
        // a signature was proposed that would have blocklisted one search
        // phrase. Nothing counts it now, and no builtin matches a search URL.
        Assert.Null(Detect.Classify(Probe()));
    }

    [Fact]
    public void AKnownSignatureStillMatches()
    {
        Blocker? blocker = Detect.Classify(new PageProbe
        {
            Url = "https://example.com/",
            Title = "Just a moment...",
        });
        Assert.NotNull(blocker);
        Assert.Equal("cloudflare-interstitial", blocker.Signature.Name);
    }

    [Fact]
    public void AShortPageWithNoSignatureIsContent()
    {
        // The pairing that motivated 005 and 010: example.com is thirty-odd
        // words, which used to be enough to seize the screen for five minutes.
        Assert.Null(Detect.Classify(new PageProbe
        {
            Url = "https://example.com/",
            Title = "Example Domain",
        }));
    }

    [Fact]
    public void ASignatureWithNoConditionCannotBeBuilt()
    {
        // The invariant pydantic's model_validator held, kept by hand here: a
        // condition-less signature matches nothing, silently, and the old dict
        // version could produce one.
        Assert.Throws<ArgumentException>(() =>
            new Signature { Name = "empty" }.Validated());
    }

    [Fact]
    public void EverySelectorInTheTableIsHandedToTheShell()
    {
        // The shell tests these against the live page and records the hits, so
        // one missing here is a signature that can never match.
        IReadOnlyList<string> selectors = Detect.SelectorsOf();
        Assert.Equal(Detect.Builtin.Count(s => s.Selector is not null), selectors.Count);
        Assert.All(selectors, s => Assert.False(string.IsNullOrEmpty(s)));
    }
}
