// How much of this page is a picture.
//
// The one measurement in this project the caller could not have made for itself.
// Everything else a read reports is derived from the text it hands over --
// `charCount` is the length of it, and ticket 016 closed unbuilt precisely
// because the markers saying content was withheld were already in that text. A
// photograph is not in it, was never in it, and no amount of reading the result
// reveals that the price list was in the picture.
//
// So this reports, and rules on nothing. `Pictures.Largest` is a number, not a
// verdict: ticket 005 removed a tier that blocked a page for having fewer words
// than a threshold, and ticket 021 removed a mode that picked an extractor by
// comparing two word counts. Both were this side ruling on a number it hands
// over anyway. The caller has `largest`, `count`, `charCount` and the text, and
// is better placed than a threshold here to say whether 0.38 on a
// 1,989-character page means the answer is in the photograph.

using System.Reflection;
using System.Text.Json;
using Microsoft.Playwright;

namespace Passenger;

public static class PicturesJs
{
    /// <summary>
    /// Ten percent of the viewport, and measured rather than picked. At 5% the
    /// count contradicts the ratio on exactly the pages that matter -- a
    /// xiaohongshu explore listing of 30 thumbnails counts 30 while its largest
    /// picture is 0.06 of the viewport, and an illustrated wikipedia article counts
    /// 5 while its largest is 0.10. At 10% both of those count 0 and a three-photo
    /// note still counts 3, so the two numbers corroborate instead of arguing.
    /// </summary>
    public const double BigEnough = 0.10;

    /// <summary>
    /// Read once at load, for walker.js's reasons in full (ticket 034): reading
    /// per call would make which code ran unanswerable.
    /// </summary>
    private static readonly string Js = ReadResource("Passenger.pictures.js");

    public static readonly Pictures Nothing =
        new() { Largest = 0.0, Count = 0, Src = "" };

    internal static string ReadResource(string name)
    {
        using Stream? stream = Assembly.GetExecutingAssembly()
            .GetManifestResourceStream(name)
            ?? throw new InvalidOperationException(
                $"{name} is missing from the assembly");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    /// <summary>
    /// Shell: what the biggest visible picture on this page is, and where.
    ///
    /// A page that cannot answer -- a wedged renderer (ticket 012), a navigation
    /// mid-flight -- reports no pictures rather than failing the read. That is
    /// the honest reading of a page nothing could measure, and there is no
    /// fallback that could quietly stand in for a bug here: an exception means
    /// zero, and zero is what a page with no pictures returns too. The
    /// measurement is not load-bearing enough to lose a whole call over.
    /// </summary>
    public static async Task<Pictures> MeasureAsync(IPage page)
    {
        try
        {
            JsonElement seen = await page.EvaluateAsync<JsonElement>(
                Js, new[] { BigEnough });
            return (seen.Deserialize<Pictures>() ?? Nothing).Validated();
        }
        catch (Exception)
        {
            return Nothing;
        }
    }
}
