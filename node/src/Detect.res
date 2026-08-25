// Functional core: deciding whether a page is blocked.
//
// Pure. No browser, no filesystem, no clock. Everything it needs was already
// measured into a `Models.probe` by the shell, which makes every rule here
// testable without launching Chrome.

open Models

let builtin: array<signature> = [
  {
    name: "cloudflare-interstitial",
    kind: Challenge,
    first: Title("^(Just a moment|Attention Required|Please Wait)"),
    rest: [],
  },
  {
    name: "cloudflare-turnstile",
    kind: Challenge,
    first: Selector("iframe[src*='challenges.cloudflare.com']"),
    rest: [],
  },
  {
    name: "recaptcha",
    kind: Challenge,
    first: Selector(
      "iframe[src*='recaptcha/api2/bframe'], iframe[src*='recaptcha/enterprise/bframe']",
    ),
    rest: [],
  },
  {
    name: "hcaptcha",
    kind: Challenge,
    first: Selector(
      "iframe[src*='hcaptcha.com'][src*='frame=challenge'], iframe[src*='newassets.hcaptcha.com/captcha']",
    ),
    rest: [],
  },
  {
    name: "arkose-funcaptcha",
    kind: Challenge,
    first: Selector("iframe[src*='arkoselabs.com'], iframe[src*='funcaptcha.com']"),
    rest: [],
  },
  {
    name: "datadome",
    kind: Challenge,
    first: Selector("iframe[src*='captcha-delivery.com'], #datadome-captcha"),
    rest: [],
  },
  {
    name: "px-human",
    kind: Challenge,
    first: Selector("#px-captcha, [id^='px-captcha']"),
    rest: [],
  },
  {
    name: "login-wall",
    kind: Login,
    first: Url("/(login|signin|sign-in|sso|auth|accounts/login)(/|\\?|$)"),
    rest: [],
  },
]

// Case-insensitive, as `Regex.IsMatch(..., RegexOptions.IgnoreCase)` was.
let matchesRe = (pattern, subject) =>
  switch RegExp.fromString(pattern, ~flags="i")->RegExp.exec(subject) {
  | Some(_) => true
  | None => false
  }

/// Every selector the shell must test against the live page.
let selectorsOf = () =>
  builtin
  ->Array.flatMap(conditions)
  ->Array.filterMap(c =>
    switch c {
    | Selector(s) => Some(s)
    | Title(_) | Url(_) => None
    }
  )

/// Every condition the signature declares must hold.
let matches = (signature, probe: probe) =>
  signature
  ->conditions
  ->Array.every(c =>
    switch c {
    | Title(re) => matchesRe(re, probe.title)
    | Url(re) => matchesRe(re, probe.url)
    | Selector(s) => probe.matchedSelectors->Array.includes(s)
    }
  )

/// A signature matched, or nothing did. `None` means the page is real content.
///
/// There used to be a second tier: a page whose word count fell below
/// `min_words` was reported as an unrecognised blocker. Ticket 005 removed it,
/// because it was a verdict with no privileged information behind it -- its
/// whole evidence was a number the caller already had, and which changed with
/// whichever extraction the caller had asked for. A signature match is a
/// positive claim this tool can defend from things the caller cannot see. A
/// short page is the caller's to judge.
///
/// The table was a parameter until ticket 019, threaded from a registry that
/// added learned rules. There is no learned list and no second table, and a
/// parameter with one possible argument advertises a variation nobody wants.
let classify = (probe: probe): option<blocker> =>
  builtin
  ->Array.find(s => matches(s, probe))
  ->Option.map(signature => {signature, probe})
