// The one orchestration, shared by every frontend.
//
// A blocked page is an *outcome*, not an error: it is the expected, designed-for
// result of pointing this tool at a protected site. So it comes back as a value
// in a union rather than as a raised exception, and each frontend decides what to
// do with it -- the CLI exits 2, the MCP server hands the agent something it can
// act on.

using System.Text.Json.Serialization;
using Microsoft.Playwright;

namespace Passenger;

/// <summary>
/// What a page holds now: a wall, or the fact that nobody looked.
///
/// A discriminated union, which C# does not have, so it is a base with a
/// `type` discriminator -- exactly the shape pydantic serialised on the Python
/// side, so the JSON a caller sees is unchanged.
///
/// It carried a third member, `Measured`, until ticket 048: a character count,
/// a title, a url and the picture geometry, taken on every reply whether or not
/// the caller wanted them. The measuring moved to the caller, which is where
/// reading a page already went with ticket 047.
/// </summary>
[JsonPolymorphic(TypeDiscriminatorPropertyName = "type")]
[JsonDerivedType(typeof(Blocked), "blocked")]
[JsonDerivedType(typeof(Unchecked), "unchecked")]
public abstract record PageOutcome;

/// <summary>
/// Nobody looked, because the caller said not to (`checkWall: false`).
///
/// A variant rather than a null `page`, for ticket 042's reason: a negative
/// nobody tested must not arrive looking like one that was. With `Measured`
/// deleted the slot would otherwise carry a wall or nothing, and *nothing*
/// would mean both "checked, and clean" and "did not check" -- which is the
/// shape 042 removed from the attach message, where a check that never ran
/// read as a page that was fine.
/// </summary>
public sealed record Unchecked : PageOutcome;

/// <summary>
/// A signature matched, so a human is genuinely required.
///
/// `evidence` and `proposed_condition` used to ride along: a page that merely
/// yielded few words was screenshotted and turned into a candidate rule.
/// That path is gone with the word-count tier (ticket 005) -- it was proposing
/// to block whole domains by their own name.
/// </summary>
public sealed record Blocked : PageOutcome
{
    [JsonPropertyName("name")]
    public required string Name { get; init; }

    [JsonPropertyName("kind")]
    public required string Kind { get; init; }

    [JsonPropertyName("url")]
    public required string Url { get; init; }

    /// <summary>
    /// The tab the wall is on, so the caller can act on it without guessing.
    /// `Ran` and `Failed` always carried one; this did not, which left an agent
    /// that wanted to summon a human deliberately reading `listTabs` and
    /// matching on a URL (ticket 018).
    /// </summary>
    [JsonPropertyName("tab")]
    public string Tab { get; init; } = "";

    [JsonPropertyName("hint")]
    public string Hint { get; init; } = "";
}

[JsonPolymorphic(TypeDiscriminatorPropertyName = "type")]
[JsonDerivedType(typeof(Ran), "ran")]
[JsonDerivedType(typeof(Failed), "failed")]
public abstract record ScriptOutcome;

/// <summary>A script that finished, and what the tab looked like afterwards.</summary>
public sealed record Ran : ScriptOutcome
{
    [JsonPropertyName("tab")]
    public required string Tab { get; init; }

    [JsonPropertyName("returned")]
    public object? Returned { get; init; }

    [JsonPropertyName("page")]
    public PageOutcome? Page { get; init; }
}

/// <summary>
/// A script that did not finish -- bad source, an exception, or a handle.
///
/// An outcome rather than an exception, for the same reason `blocked` is one:
/// the caller's next move is to fix the script and call again, and it needs
/// the line number and the state of the tab to do that. The tab is left
/// exactly where the script left it.
/// </summary>
public sealed record Failed : ScriptOutcome
{
    [JsonPropertyName("tab")]
    public required string Tab { get; init; }

    [JsonPropertyName("code")]
    public required string Code { get; init; }

    [JsonPropertyName("error")]
    public required string Error { get; init; }

    [JsonPropertyName("where")]
    public string Where { get; init; } = "";

    [JsonPropertyName("page")]
    public PageOutcome? Page { get; init; }
}

public static class Service
{
    /// <summary>
    /// Is a known vendor's wall on this page?
    ///
    /// The tail every read shares. It used to extract the page as well and hand
    /// both back; extraction left with `fetch` (ticket 046) and what remains is
    /// the one judgement this side is still allowed to make -- a match against a
    /// fixed table of vendors' own markup, which is a measurement because a vendor
    /// either serves that markup or does not (ticket 038).
    /// </summary>
    public static async Task<Blocker?> InspectAsync(IPage page) =>
        Detect.Classify(await Probe.MeasureAsync(page));

    /// <summary>
    /// The passthrough door: caller-supplied code, run against a page.
    ///
    /// Everything this project knows how to do to a page is reachable from here
    /// without being rewrapped, because what is handed over is `Page` itself
    /// (ticket 004). What this function adds is the envelope: which tab, a bounded
    /// clock, and a reading of the ending page -- so a challenge met halfway
    /// through a sequence comes back as `blocked`, not as a puzzling empty string.
    /// </summary>
    public static async Task<ScriptOutcome> RunAsync(ScriptRequest request)
    {
        request.Validated();
        Lanes.Sweep();
        Lanes.Require(request.Lane);
        Lanes.Touch(request.Lane);
        await using Session session = await Session.OpenAsync();
        IPage page = await session.PageForAsync(request.Lane, request.Tab);
        // Every Playwright call inside the script inherits this, so a wait on
        // a selector that never appears ends the call instead of the session.
        // A script that loops without calling Playwright is not interruptible;
        // that is the honest limit of running code in-process.
        page.SetDefaultTimeout(request.TimeoutS * 1000);
        string tab = await session.TargetIdAsync(page);

        ScriptOutcome outcome;
        try
        {
            object? returned = await Script.ExecuteAsync(request.Source, page);
            outcome = new Ran
            {
                Tab = tab,
                Returned = returned,
                Page = await LookAsync(page, tab, request.CheckWall),
            };
        }
        catch (ScriptException failure)
        {
            outcome = new Failed
            {
                Tab = tab,
                Code = failure.Code.Value(),
                Error = failure.PlainMessage,
                Where = failure.Detail ?? "",
                Page = await LookAsync(page, tab, request.CheckWall),
            };
        }

        // A script may have opened tabs of its own -- window.open, or a link
        // with target="_blank". Attributing them to the lane that caused them
        // is what keeps them from becoming invisible and uncollectable.
        var open = new List<string>();
        foreach (IPage openPage in session.Context.Pages)
        {
            open.Add(await session.TargetIdAsync(openPage));
        }

        Lanes.Reconcile(open, Targets.Openers());
        Lanes.Touch(request.Lane);
        return outcome;
    }

    /// <summary>
    /// What the tab holds now: a wall, or nothing this side went looking for.
    ///
    /// Taken unless the caller says otherwise, where ticket 047 had made it
    /// unconditional. 047 deleted a `readPage` switch on the reasoning that
    /// nobody needs to opt out of something cheap, and that was right about
    /// what the reply carried *then* -- a character count and a picture
    /// geometry, neither of which the caller could refuse. Ticket 048 deleted
    /// those, which leaves the wall probe as the only work here nobody asked
    /// for: two round trips, a title and a selector match, on every call. A
    /// caller driving one page across many calls pays them every time, and
    /// that caller is the one `checkWall` is for.
    /// </summary>
    private static async Task<PageOutcome?> LookAsync(IPage page, string tab, bool checkWall)
    {
        if (!checkWall)
        {
            return new Unchecked();
        }

        Blocker? blocker = await InspectAsync(page);
        return blocker is null
            ? null
            : ToBlocked(blocker, tab,
                "showBrowser with this tab and a wait; solve it, then call again "
                + "with this same tab -- it is still open, and still there");
    }

    private static Blocked ToBlocked(Blocker blocker, string tab, string hint) => new()
    {
        Name = blocker.Signature.Name,
        Kind = blocker.Signature.Kind.Value(),
        Url = blocker.Probe.Url,
        Tab = tab,
        Hint = hint,
    };
}
