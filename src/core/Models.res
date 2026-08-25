// Every boundary shape, as records the compiler will not let you build wrong.

type kind = Challenge | Login | Unknown

// What a signature tests. The C# side had three nullable fields -- TitleRe,
// UrlRe, Selector -- and a `Validated()` that threw when all three were null,
// because a condition-less signature matches nothing, silently. `Models.cs`
// says that invariant came from pydantic's model_validator and was kept by
// hand; `DetectTests.cs` spent a test holding it.
//
// Here it is neither: a signature carries one condition plus any others, so a
// signature with no condition cannot be written down. That is the same move
// ticket 021 made when it took `word_count` off PageProbe and the comment in
// `DetectTests.cs` records -- "structural rather than tested".
type condition =
  | Title(string)
  | Url(string)
  | Selector(string)

type signature = {
  name: string,
  kind: kind,
  first: condition,
  rest: array<condition>,
}

let conditions = s => [s.first]->Array.concat(s.rest)

/// The wire spelling of a kind, written out for the reason `Errors.codeToString` is:
/// a caller may be branching on it.
let kindToString = kind =>
  switch kind {
  | Challenge => "challenge"
  | Login => "login"
  | Unknown => "unknown"
  }

/// What the shell measured, and all `Detect` is allowed to see.
type probe = {
  url: string,
  title: string,
  matchedSelectors: array<string>,
}

type blocker = {
  signature: signature,
  probe: probe,
}

/// How a tab is holding the attach open, when it is.
///
/// Two different failures wearing one symptom. `Silent` is ticket 012's: the
/// renderer has stopped answering anything, and stopping its load frees it with
/// the document it already had intact. `Uncommitted` is ticket 042's: the
/// renderer answers everything instantly and holds no document at all, because
/// the navigation that created it is still waiting on a server that has not sent
/// headers.
///
/// Measured, and the reason they cannot share a remedy: `Page.stopLoading` on an
/// Uncommitted tab is answered, clears the pending URL, and leaves the attach
/// hanging exactly as before. Navigating it to about:blank frees it -- and costs
/// nothing, since a tab with no document has nothing to lose.
type wedge = Silent | Uncommitted

// Declaration order, which is the order `stuckSummary` reads them in so a line
// reads the same way twice for the same browser.
let wedges = [Silent, Uncommitted]

let wedgeToString = w =>
  switch w {
  | Silent => "silent"
  | Uncommitted => "uncommitted"
  }

/// One entry from Chrome's target list, as the CDP HTTP endpoint reports it.
///
/// That endpoint is served by the browser process, so it keeps answering when a
/// page's renderer does not. This shape exists for exactly that moment.
type target = {
  id: string,
  @as("type") type_: string,
  url: string,
  title: string,
  @as("webSocketDebuggerUrl") websocketUrl: string,
}

/// Tabs only. Chrome also lists its own UI, workers and extensions.
let isPage = t => t.type_ == "page"

/// How Chrome is launched.
type backendName = Nested | NoBackend

/// How a human is given a look at the hidden browser.
type presenterName = Local | Web | NoPresenter

// The wire spellings, written out for the same reason `Errors.codeToString` is: a
// session record on disk or an agent's saved string is holding one of these,
// so it is a contract rather than a rendering of a constructor name. The
// constructors read `NoBackend` / `NoPresenter` rather than `None` twice over,
// because ReScript has one constructor namespace per type but `None` is already
// the option's, and shadowing it inside this module would be a trap for every
// later reader.
let backendToString = name =>
  switch name {
  | Nested => "nested"
  | NoBackend => "none"
  }

let presenterToString = name =>
  switch name {
  | Local => "local"
  | Web => "web"
  | NoPresenter => "none"
  }

/// Parse a backend name as the environment spells it.
let parseBackend = text =>
  switch text {
  | "nested" => Some(Nested)
  | "none" => Some(NoBackend)
  | _ => None
  }

/// Parse a presenter name as the environment spells it.
let parsePresenter = text =>
  switch text {
  | "local" => Some(Local)
  | "web" => Some(Web)
  | "none" => Some(NoPresenter)
  | _ => None
  }

let backendNames = ["nested", "none"]

/// What ends a `showBrowser` wait.
type waitFor = Closed | Unblocked

let parseWaitFor = text =>
  switch text {
  | "closed" => Some(Closed)
  | "unblocked" => Some(Unblocked)
  | _ => None
  }

/// How a window backend wants Chrome started.
type launchPlan = {argv: array<string>, env: Dict.t<string>}
