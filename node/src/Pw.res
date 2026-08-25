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
