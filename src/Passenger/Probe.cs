// Imperative shell: measuring a live page.
//
// Selector evaluation and screenshots need a browser; the decisions made from
// them do not. This module is the boundary between those two worlds.

using Microsoft.Playwright;

namespace Passenger;

public static class Probe
{
    private const string MatchJs =
        "sels => sels.filter(s => { try { return !!document.querySelector(s); }"
        + " catch (e) { return false; } })";

    /// <summary>
    /// Measure everything detection needs, in as few round trips as possible.
    ///
    /// The extraction used to be handed in, for a `word_count` no rule had read
    /// since ticket 005. Ticket 021 dropped the field, and with it this
    /// function's one dependency on how the caller chose to read the page.
    ///
    /// The signature table used to be handed in as well, from a registry that
    /// could add learned rules to it. Ticket 019 removed the learning, so there
    /// is one table and `SelectorsOf` reads it directly.
    /// </summary>
    public static async Task<PageProbe> MeasureAsync(IPage page)
    {
        string title;
        try
        {
            title = await page.TitleAsync();
        }
        catch (Exception)
        {
            title = "";
        }

        IReadOnlyList<string> selectors = Detect.SelectorsOf();
        string[] hits;
        try
        {
            hits = await page.EvaluateAsync<string[]>(MatchJs, selectors) ?? [];
        }
        catch (Exception)
        {
            hits = [];
        }

        return new PageProbe
        {
            Url = page.Url,
            Title = title,
            MatchedSelectors = new HashSet<string>(hits),
        };
    }

    /// <summary>Clock access, isolated so the core stays deterministic.</summary>
    public static long Now() => DateTimeOffset.UtcNow.ToUnixTimeSeconds();
}
