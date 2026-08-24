// Functional core: deciding whether a page is blocked.
//
// Pure. No browser, no filesystem, no clock. Everything it needs was already
// measured into a PageProbe by the shell, which makes every rule here testable
// without launching Chrome.

using System.Text.RegularExpressions;

namespace Passenger;

public static class Detect
{
    public static IReadOnlyList<Signature> Builtin { get; } =
    [
        new Signature
        {
            Name = "cloudflare-interstitial",
            TitleRe = @"^(Just a moment|Attention Required|Please Wait)",
        }.Validated(),
        new Signature
        {
            Name = "cloudflare-turnstile",
            Selector = "iframe[src*='challenges.cloudflare.com']",
        }.Validated(),
        new Signature
        {
            Name = "recaptcha",
            Selector = "iframe[src*='recaptcha/api2/bframe'], "
                       + "iframe[src*='recaptcha/enterprise/bframe']",
        }.Validated(),
        new Signature
        {
            Name = "hcaptcha",
            Selector = "iframe[src*='hcaptcha.com'][src*='frame=challenge'], "
                       + "iframe[src*='newassets.hcaptcha.com/captcha']",
        }.Validated(),
        new Signature
        {
            Name = "arkose-funcaptcha",
            Selector = "iframe[src*='arkoselabs.com'], iframe[src*='funcaptcha.com']",
        }.Validated(),
        new Signature
        {
            Name = "datadome",
            Selector = "iframe[src*='captcha-delivery.com'], #datadome-captcha",
        }.Validated(),
        new Signature
        {
            Name = "px-human",
            Selector = "#px-captcha, [id^='px-captcha']",
        }.Validated(),
        new Signature
        {
            Name = "login-wall",
            Kind = SignatureKind.Login,
            UrlRe = @"/(login|signin|sign-in|sso|auth|accounts/login)(/|\?|$)",
        }.Validated(),
    ];

    /// <summary>Every selector the shell must test against the live page.</summary>
    public static IReadOnlyList<string> SelectorsOf() =>
        [.. Builtin.Where(s => s.Selector is not null).Select(s => s.Selector!)];

    /// <summary>Every condition the signature declares must hold.</summary>
    public static bool Matches(Signature signature, PageProbe probe)
    {
        if (signature.TitleRe is not null
            && !Regex.IsMatch(probe.Title, signature.TitleRe, RegexOptions.IgnoreCase))
        {
            return false;
        }

        if (signature.UrlRe is not null
            && !Regex.IsMatch(probe.Url, signature.UrlRe, RegexOptions.IgnoreCase))
        {
            return false;
        }

        if (signature.Selector is not null
            && !probe.MatchedSelectors.Contains(signature.Selector))
        {
            return false;
        }

        return true;
    }

    /// <summary>
    /// A signature matched, or nothing did. Null means the page is real content.
    ///
    /// There used to be a second tier: a page whose word count fell below
    /// `min_words` was reported as an unrecognised blocker. It was removed in
    /// ticket 005 because it was a verdict with no privileged information behind
    /// it. Its entire evidence was a number the caller already had, on
    /// `Fetched.char_count` -- and worse, that number came from whichever
    /// extraction the caller's `mode` happened to produce, so the same page came
    /// back as content or as blocked depending on a presentation choice.
    ///
    /// A signature match is a positive claim this tool can defend, made from
    /// things the caller cannot see. A short page is the caller's to judge.
    ///
    /// The table was a parameter until ticket 019, threaded here from a registry
    /// that added a learned list to it. There is no learned list now and there is
    /// no second table: `Builtin` is knowledge about how challenge vendors
    /// identify themselves, true regardless of who is calling. A parameter with
    /// one possible argument advertises a variation that is not wanted.
    /// </summary>
    public static Blocker? Classify(PageProbe probe)
    {
        foreach (Signature signature in Builtin)
        {
            if (Matches(signature, probe))
            {
                return new Blocker { Signature = signature, Probe = probe };
            }
        }

        return null;
    }
}
