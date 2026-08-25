// Imperative shell: measuring a live page.
//
// Selector evaluation and screenshots need a browser; the decisions made from
// them do not. This module is the boundary between those two worlds.

open Models

/// Which of these selectors match, asked once for the whole table.
///
/// A real function, not a string, and that distinction cost a silent bug worth
/// naming. Playwright .NET takes JavaScript as a string and works out that a
/// string like `sels => ...` is a function. This client does not: `typeof
/// pageFunction === "function"` is what decides, so the same string is evaluated
/// as an *expression*, which produces a function object in the page, which is
/// not serialisable, which comes back as `undefined`. Nothing throws. The probe
/// then carries no matched selectors and every page reads as clean -- a wall
/// reported as an open road, which is the exact shape ticket 042 removed from
/// the attach message.
let match: 'a = %raw(`sels => sels.filter(s => {
  try { return !!document.querySelector(s); } catch (e) { return false; }
})`)

/// Measure everything detection needs, in as few round trips as possible.
///
/// The extraction used to be handed in, for a `word_count` no rule had read
/// since ticket 005. Ticket 021 dropped the field, and with it this function's
/// one dependency on how the caller chose to read the page.
///
/// The signature table used to be handed in as well, from a registry that could
/// add learned rules to it. Ticket 019 removed the learning, so there is one
/// table and `selectorsOf` reads it directly.
let measure = async (page): probe => {
  let title = switch await Pw.title(page) {
  | title => title
  | exception _ => ""
  }

  // An empty measurement on failure, which is what the C# side did and is not
  // free: it reads as "no wall", not as "did not look". The caller's `checkWall`
  // is what distinguishes those, and it is spent before this point -- so what is
  // being said here is that a page whose renderer would not answer is reported
  // the way a page with nothing on it is. Left as it was rather than widened,
  // because changing it is a change to what a reply means.
  let matchedSelectors = switch await Pw.evaluate(page, match, Detect.selectorsOf()) {
  | hits if Array.isArray(hits) => hits
  | _ => []
  | exception _ => []
  }

  {url: Pw.url(page), title, matchedSelectors}
}

/// Clock access, isolated so the core stays deterministic.
let now = () => Math.floor(Date.now() /. 1000.0)
