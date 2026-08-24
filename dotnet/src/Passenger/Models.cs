// Domain models.
//
// Every shape that crosses a boundary -- what we measured about a page, what
// the CLI asked for -- is parsed into one of these once, at the edge. Nothing
// downstream sees a raw dictionary.
//
// Pydantic's frozen models become records with init-only members. What pydantic
// did at construction time and C# does not, this file does by hand: the bounds
// and the at-least-one-condition invariant are checked in constructors, so the
// shapes pydantic could not express still cannot exist here either.

using System.Text.Json.Serialization;

namespace Passenger;

public enum SignatureKind { Challenge, Login, Unknown }

/// <summary>
/// What ends a `show_browser` wait.
///
/// Two different facts, and the difference is the point (ticket 018). Closed
/// is the human saying they are done, which is the one completion signal this
/// tool does not have to infer. Unblocked is the page saying the wall is gone,
/// which is stronger -- a human can close a viewer without solving anything --
/// but only reaches walls the fixed signature table can name.
/// </summary>
public enum WaitFor { Closed, Unblocked }

/// <summary>
/// How a tab is holding the attach open, when it is.
///
/// Two different failures wearing one symptom. Silent is ticket 012's: the
/// renderer has stopped answering anything, and stopping its load frees it
/// with the document it already had intact. Uncommitted is ticket 042's: the
/// renderer answers everything instantly and holds no document at all,
/// because the navigation that created it is still waiting on a server that
/// has not sent headers.
///
/// Measured, and the reason they cannot share a remedy: `Page.stopLoading` on
/// an Uncommitted tab is answered, clears the pending URL, and leaves the
/// attach hanging exactly as before. Navigating it to about:blank frees it --
/// and costs nothing, since a tab with no document has nothing to lose.
/// </summary>
public enum Wedge { Silent, Uncommitted }

public enum WaitUntil { Load, DomContentLoaded, NetworkIdle, Commit }

/// <summary>How Chrome is launched.</summary>
public enum BackendName { Nested, None }

/// <summary>How a human is given a look at the hidden browser.</summary>
public enum PresenterName { Local, Web, None }

/// <summary>
/// The wire spellings of every enum that crosses a boundary.
///
/// The Python side got these free from `str, Enum`; here they are written out,
/// for the reason <see cref="ErrorCodeNames"/> gives -- an agent, a CLI user or
/// a session record may be holding one of these strings, so they are a contract
/// rather than a rendering of a member name.
/// </summary>
public static class EnumNames
{
    public static string Value(this SignatureKind kind) => kind switch
    {
        SignatureKind.Challenge => "challenge",
        SignatureKind.Login => "login",
        SignatureKind.Unknown => "unknown",
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    public static string Value(this WaitFor wait) => wait switch
    {
        WaitFor.Closed => "closed",
        WaitFor.Unblocked => "unblocked",
        _ => throw new ArgumentOutOfRangeException(nameof(wait)),
    };

    public static string Value(this Wedge wedge) => wedge switch
    {
        Wedge.Silent => "silent",
        Wedge.Uncommitted => "uncommitted",
        _ => throw new ArgumentOutOfRangeException(nameof(wedge)),
    };

    public static string Value(this WaitUntil until) => until switch
    {
        WaitUntil.Load => "load",
        WaitUntil.DomContentLoaded => "domcontentloaded",
        WaitUntil.NetworkIdle => "networkidle",
        WaitUntil.Commit => "commit",
        _ => throw new ArgumentOutOfRangeException(nameof(until)),
    };

    public static string Value(this BackendName name) => name switch
    {
        BackendName.Nested => "nested",
        BackendName.None => "none",
        _ => throw new ArgumentOutOfRangeException(nameof(name)),
    };

    public static string Value(this PresenterName name) => name switch
    {
        PresenterName.Local => "local",
        PresenterName.Web => "web",
        PresenterName.None => "none",
        _ => throw new ArgumentOutOfRangeException(nameof(name)),
    };

    /// <summary>Parse a backend name as the environment spells it, or null.</summary>
    public static BackendName? ParseBackend(string text) => text switch
    {
        "nested" => BackendName.Nested,
        "none" => BackendName.None,
        _ => null,
    };

    /// <summary>Parse a presenter name as the environment spells it, or null.</summary>
    public static PresenterName? ParsePresenter(string text) => text switch
    {
        "local" => PresenterName.Local,
        "web" => PresenterName.Web,
        "none" => PresenterName.None,
        _ => null,
    };

    public static IReadOnlyList<string> BackendNames { get; } = ["nested", "none"];
}

/// <summary>
/// A rule for recognising a blocked page.
///
/// At least one condition is required. The old dict version could produce a
/// condition-less signature that silently matched nothing; making it a
/// construction-time invariant means that shape can no longer exist.
///
/// `pending_review`, `seen_at` and `evidence` were carried for signatures the
/// tool proposed to itself from pages it found thin. Ticket 005 deleted what
/// wrote them and ticket 019 deleted the store that held them: every value of
/// this type is now a builtin, written by hand and true of a vendor rather
/// than of a site.
/// </summary>
public sealed record Signature
{
    public required string Name { get; init; }
    public SignatureKind Kind { get; init; } = SignatureKind.Challenge;
    public string? TitleRe { get; init; }
    public string? UrlRe { get; init; }
    public string? Selector { get; init; }

    public Signature()
    {
    }

    /// <summary>
    /// The invariant pydantic's `model_validator` held: a signature with no
    /// condition matches nothing, silently, and must not be constructible.
    /// </summary>
    public Signature Validated()
    {
        if (TitleRe is null && UrlRe is null && Selector is null)
        {
            throw new ArgumentException($"signature '{Name}' has no condition");
        }

        return this;
    }
}

/// <summary>
/// One entry from Chrome's target list, as the CDP HTTP endpoint reports it.
///
/// That endpoint is served by the browser process, so it keeps answering when
/// a page's renderer does not. This shape exists for exactly that moment.
/// </summary>
public sealed record Target
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = "";

    [JsonPropertyName("type")]
    public string Type { get; init; } = "";

    [JsonPropertyName("url")]
    public string Url { get; init; } = "";

    [JsonPropertyName("title")]
    public string Title { get; init; } = "";

    [JsonPropertyName("webSocketDebuggerUrl")]
    public string WebsocketUrl { get; init; } = "";

    /// <summary>Tabs only. Chrome also lists its own UI, workers and extensions.</summary>
    [JsonIgnore]
    public bool IsPage => Type == "page";
}

/// <summary>
/// What the shell measured about a loaded page.
///
/// Selector evaluation needs the live page, so the shell tests every candidate
/// selector up front and records the hits here. Detection then becomes a pure
/// function of this record, and is testable without a browser.
///
/// It carried a `word_count` until ticket 021. Nothing had read it since 005
/// deleted the tier that did, and while it sat here the same page could be
/// probed with two different numbers depending on the caller's `mode` -- a
/// presentation choice reaching into a verdict. Leaving it off means that
/// cannot be written, rather than merely not being done.
/// </summary>
public sealed record PageProbe
{
    public required string Url { get; init; }
    public required string Title { get; init; }
    public IReadOnlySet<string> MatchedSelectors { get; init; } =
        new HashSet<string>();
}

/// <summary>
/// A signature matched this page, so a human is genuinely required.
///
/// Was `KnownBlocker`, against a `NovelBlocker` that meant only "this page
/// had fewer words than a number I was handed". That second kind is gone
/// (ticket 005), and with one kind left the distinguishing adjective is
/// noise -- as is the discriminator that let a union be told apart.
/// </summary>
public sealed record Blocker
{
    public required Signature Signature { get; init; }
    public required PageProbe Probe { get; init; }
}

/// <summary>
/// What the page renders that is not text (ticket 017).
///
/// Geometry rather than a count, because a bare count is noise on every page
/// ever made. Measured across twelve pages, the largest visible picture as a
/// share of the viewport separates a three-photo note (0.38) from a listing
/// of thirty thumbnails (0.06), while both the count and the summed area call
/// the listing the more picture-borne of the two -- it has thirty boxes and
/// 1.72 viewports of them, against three and 1.16.
///
/// `Src` is how to reach that picture, not necessarily a URL: two of the five
/// tags measured -- inline `svg` and `canvas` -- have no URL to give, so it
/// falls back to a CSS selector, which `page.Locator(sel).ScreenshotAsync()`
/// takes (ticket 014). A `data:` placeholder parked by a lazy loader does the
/// same.
/// </summary>
public sealed record Pictures
{
    /// <summary>
    /// The largest visible picture's area, over the viewport's. Above 1.0 for
    /// an element rendered larger than the window, which is ordinary on a
    /// marketing page: apple.com's hero measures 1.92.
    /// </summary>
    [JsonPropertyName("largest")]
    public double Largest { get; init; }

    /// <summary>How many clear <see cref="PicturesJs.BigEnough"/> of the viewport.</summary>
    [JsonPropertyName("count")]
    public int Count { get; init; }

    [JsonPropertyName("src")]
    public string Src { get; init; } = "";

    /// <summary>The bounds pydantic held with `Field(ge=0)`.</summary>
    public Pictures Validated()
    {
        if (Largest < 0.0)
        {
            throw new ArgumentException("largest must be at or above 0");
        }

        if (Count < 0)
        {
            throw new ArgumentException("count must be at or above 0");
        }

        return this;
    }
}

/// <summary>
/// One call at the passthrough door (ticket 013).
///
/// The only door there is, since ticket 046 retired `fetch`. A script decides
/// its own navigation, so nothing here says how to arrive; what is left is
/// which tab, whose lane, and how long any one Playwright call may take.
///
/// There is no `extract_mode` and no `read_page` because there is no
/// extraction. The reply carries what the ending page *measures* -- a
/// character count, the pictures, a vendor's wall -- and never what it means.
/// </summary>
public sealed record ScriptRequest
{
    public required string Source { get; init; }
    public required string Lane { get; init; }

    /// <summary>
    /// Null means "a blank tab", which is the one-shot case. A targetId
    /// continues a sequence, or picks up the tab a human just navigated. It
    /// must be a tab this lane owns; another lane's is refused as absent.
    /// </summary>
    public string? Tab { get; init; }

    public int TimeoutS { get; init; } = 60;

    public bool AsJson { get; init; }

    /// <summary>The bound pydantic held with `Field(ge=1)`.</summary>
    public ScriptRequest Validated()
    {
        if (TimeoutS < 1)
        {
            throw new ArgumentException("timeout_s must be at least 1");
        }

        return this;
    }
}

/// <summary>How a window backend wants Chrome started.</summary>
public sealed record LaunchPlan
{
    public required IReadOnlyList<string> Argv { get; init; }
    public IReadOnlyDictionary<string, string> Env { get; init; } =
        new Dictionary<string, string>();
}
