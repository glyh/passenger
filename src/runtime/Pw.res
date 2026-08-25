// Playwright, bound to what the *shell* touches -- about fifteen members. The
// caller's script never comes through here: it is raw JavaScript calling
// Playwright directly inside the vm, which is the entire point of the port.

type browser
type context
type page

type chromium
@module("playwright-core") external chromium: chromium = "chromium"

@send external connectOverCDP: (chromium, string) => promise<browser> = "connectOverCDP"
@send external contexts: browser => array<context> = "contexts"
@send external pages: context => array<page> = "pages"
@send external newPage: context => promise<page> = "newPage"
@send external closeBrowser: browser => promise<unit> = "close"

@send external goto: (page, string) => promise<Nullable.t<'resp>> = "goto"
@send external title: page => promise<string> = "title"
@send external url: page => string = "url"
@send external closePage: page => promise<unit> = "close"

/// Attaching, with the driver's own deadline as well as ours (see `Session`).
type connectOptions = {timeout: int}
@send
external connectOverCDPWith: (chromium, string, connectOptions) => promise<browser> =
  "connectOverCDP"

// CDP through Playwright, for the questions only an attached session can ask:
// which target a page *is*, and where the browser is putting its window. The
// unattached half of the same protocol lives in `Targets`, and the split is not
// arbitrary -- that half exists for when this half cannot be reached at all.
type cdp
@send external newCDPSession: (context, page) => promise<cdp> = "newCDPSession"
@send external newBrowserCDPSession: browser => promise<cdp> = "newBrowserCDPSession"
@send external send: (cdp, string) => promise<JSON.t> = "send"
@send external sendWith: (cdp, string, {..}) => promise<JSON.t> = "send"

/// Evaluate in the page. The `'arg` is structured-cloned in, which is what lets
/// `Probe` send the whole selector table in one round trip.
///
/// `'fn`, not `string`: this client decides what to do with the first argument
/// by `typeof`, and a function passed as a string is run as an expression rather
/// than called. See the comment over `Probe.match`.
@send external evaluate: (page, 'fn, 'arg) => promise<'r> = "evaluate"

/// The per-call budget every Playwright operation inside a script inherits.
@send external setDefaultTimeout: (page, int) => unit = "setDefaultTimeout"

/// Raise a tab, so the human lands on the page the caller meant.
@send external bringToFront: page => promise<unit> = "bringToFront"

// Reached only by the live checks, which measure what these serialise to.
@send external locator: (page, string) => 'locator = "locator"
@send external frameLocator: (page, string) => 'frameLocator = "frameLocator"
@get external request: page => 'apiRequest = "request"
@get external keyboard: page => 'keyboard = "keyboard"
@get external mouse: page => 'mouse = "mouse"
