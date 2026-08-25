// Liveness classification. Pure: a fixture probe, no browser.
//
// The oracle was `tests/Passenger.Tests/DetectTests.cs`, and four of its five
// cases are here by name. The fifth, `ASignatureWithNoConditionCannotBeBuilt`,
// **cannot be written any more** -- `Models.signature` carries one condition
// plus any others, so a signature with no condition is not a value this
// language will construct. That is the same trade the C# file records for
// `TheModeCanNoLongerChangeTheVerdict` after ticket 021 took `word_count` off
// the probe: the guarantee moved from a test to the shape.
//
// The cases below the ported four are new. The C# suite checks one signature
// matching; a table of eight where seven are never exercised is seven rules
// nobody would notice breaking.

open Models

let probe = (~title="珠海长隆海洋王国 - 小红书搜索", ~url="https://www.xiaohongshu.com/search_result?keyword=x", ~selectors=[]) => {
  url,
  title,
  matchedSelectors: selectors,
}

T.test("a rendered CJK listing is not blocked", () => {
  // Ticket 008: this page counted 66 words, under the default 80, so a fully
  // rendered listing with nothing in its way was called blocked. Nothing counts
  // it now, and no builtin matches a search URL.
  T.equal(Detect.classify(probe()), None)
})

T.test("a known signature still matches", () => {
  switch Detect.classify(probe(~url="https://example.com/", ~title="Just a moment...")) {
  | Some(b) => T.equal(b.signature.name, "cloudflare-interstitial")
  | None => T.ok(false)
  }
})

T.test("a short page with no signature is content", () => {
  // The pairing that motivated 005 and 010: example.com is thirty-odd words,
  // which used to be enough to seize the screen for five minutes.
  T.equal(Detect.classify(probe(~url="https://example.com/", ~title="Example Domain")), None)
})

T.test("every selector in the table is handed to the shell", () => {
  // The shell tests these against the live page and records the hits, so one
  // missing here is a signature that can never match.
  let selectors = Detect.selectorsOf()
  T.equal(
    selectors->Array.length,
    Detect.builtin
    ->Array.flatMap(Models.conditions)
    ->Array.filter(c =>
      switch c {
      | Selector(_) => true
      | Title(_) | Url(_) => false
      }
    )
    ->Array.length,
  )
  T.ok(selectors->Array.every(s => s != ""))
})

// --- every rule in the table, exercised once -------------------------------

let bySelector = name =>
  switch Detect.builtin->Array.find(s => s.name == name) {
  | Some(s) =>
    switch s.first {
    | Selector(sel) => sel
    | Title(_) | Url(_) => ""
    }
  | None => ""
  }

let selectorRules = [
  "cloudflare-turnstile",
  "recaptcha",
  "hcaptcha",
  "arkose-funcaptcha",
  "datadome",
  "px-human",
]

selectorRules->Array.forEach(name =>
  T.test("selector rule matches: " ++ name, () => {
    let hit = Detect.classify(probe(~selectors=[bySelector(name)]))
    switch hit {
    | Some(b) => T.equal(b.signature.name, name)
    | None => T.ok(false)
    }
  })
)

T.test("a selector the shell did not report does not match", () => {
  // The probe carries what was *found*, so an unmatched selector must not be
  // inferred from the table's own text.
  T.equal(Detect.classify(probe(~selectors=[])), None)
})

T.test("the login wall is a URL rule, and is kind Login", () => {
  switch Detect.classify(probe(~url="https://site.test/accounts/login?next=/", ~title="Sign in")) {
  | Some(b) =>
    T.equal(b.signature.name, "login-wall")
    T.equal(b.signature.kind, Login)
  | None => T.ok(false)
  }
})

T.test("a URL merely containing the word login does not match", () => {
  // The rule is anchored on a path segment: `/login/` or `/login?` or `/login`
  // at the end. A blog post about logins is not a wall.
  T.equal(Detect.classify(probe(~url="https://site.test/blog/logins-explained", ~title="Logins")), None)
})

T.test("matching is case-insensitive, as RegexOptions.IgnoreCase was", () => {
  switch Detect.classify(probe(~url="https://example.com/", ~title="JUST A MOMENT...")) {
  | Some(b) => T.equal(b.signature.name, "cloudflare-interstitial")
  | None => T.ok(false)
  }
})

T.test("the blocker carries the probe it was decided from", () => {
  let p = probe(~url="https://example.com/", ~title="Just a moment...")
  switch Detect.classify(p) {
  | Some(b) => T.equal(b.probe.title, "Just a moment...")
  | None => T.ok(false)
  }
})
