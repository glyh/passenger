"""The CLI boundary.

cyclopts lives here and nowhere else: core modules raise domain errors and
return models, and this is the single place that decides what a failure looks
like on a terminal.
"""
import json
import sys
from pathlib import Path
from typing import Annotated, assert_never

import cyclopts

from . import browser, launch, present, service, session as session_mod, targets
from .config import settings
from .detect import BUILTIN
from .errors import AgentBrowserError, ErrorCode
from .models import ExtractMode, FetchRequest, ScriptRequest, WaitUntil

app = cyclopts.App(
    name="agent-browser",
    help="Fetch web context through a real, logged-in Chrome, "
         "with a human handoff when a site puts up a challenge.",
)


@app.command
def fetch(
    url: str,
    *,
    mode: Annotated[ExtractMode, cyclopts.Parameter(name=["--mode", "--extract"])],
    wait: WaitUntil = WaitUntil.DOM_CONTENT_LOADED,
    settle: int = 1500,
    handoff_enabled: Annotated[bool, cyclopts.Parameter(name=["--handoff"])] = True,
    new_tab: bool = False,
    keep_tab: bool = False,
    close_tabs: bool = False,
    json_out: Annotated[bool, cyclopts.Parameter(name=["--json"])] = False,
) -> None:
    """Fetch a URL and print its content.

    Reads the page as it loads: whatever it defers until you scroll or click
    is not in the output, and the page's own stated count is often the only
    sign. Use `script` to reach the rest.

    What is in a picture is not in the output either, and says nothing at all
    -- a page whose answer lives in a photograph reads as a short page rather
    than a truncated one. With --json, `largest_image` is the biggest thing
    the page renders that is not text, as a share of the window; read it
    against `char_count`, and reach the picture with `largest_image_src`.

    Parameters
    ----------
    url
        Page to fetch.
    mode
        Required. article removes boilerplate, and is right for a document --
        an article, a post, a docs page. dom keeps every visible line, and is
        right for a listing, a feed, a profile or a search result, where
        article throws the cards away and returns the footer.
    settle
        Milliseconds to let client-side rendering finish.
    handoff_enabled
        With --no-handoff, exit on a blocker instead of asking for help.
    close_tabs
        Close every other tab afterwards, clearing tabs orphaned by earlier
        runs.
    json_out
        Emit a JSON record instead of bare markdown.
    """
    request = FetchRequest(
        url=url,
        extract_mode=mode,
        wait_until=wait,
        settle_ms=settle,
        allow_handoff=handoff_enabled,
        reuse_tab=not new_tab,
        keep_tab=keep_tab,
        close_tabs=close_tabs,
        as_json=json_out,
        handoff_timeout_s=settings.handoff_timeout_s,
    )
    _render(service.fetch(request), json_out)


def _render(outcome: service.FetchOutcome, as_json: bool) -> None:
    """The CLI's reading of an outcome: blocked is a failure worth exiting on."""
    match outcome:
        case service.Fetched():
            if as_json:
                json.dump(outcome.model_dump(mode="json"), sys.stdout, indent=2)
                print()
            else:
                print(outcome.markdown)
        case service.Blocked():
            json.dump(outcome.model_dump(mode="json"), sys.stderr, indent=2)
            print(file=sys.stderr)
            raise SystemExit(2)
        case _ as unreachable:
            assert_never(unreachable)


@app.command
def script(
    file: str = "-",
    *,
    mode: ExtractMode,
    tab: str | None = None,
    read_page: bool = True,
    timeout: int = 60,
    json_out: Annotated[bool, cyclopts.Parameter(name=["--json"])] = False,
) -> None:
    """Run a Playwright script against a tab, and print where it ends up.

    The same door the MCP server offers, for driving a page by hand: reaching
    content behind a search box, or reading the tab a human just navigated to.

    Parameters
    ----------
    file
        Script to run. Defaults to stdin, so it reads from a heredoc.
    mode
        Required, as on `fetch`: article for a document, dom for a listing.
    tab
        Tab id to run against, from `tabs`. Omitted means a fresh blank tab.
    read_page
        With --no-read-page, skip extracting the ending page.
    timeout
        Seconds each Playwright operation inside the script may take.
    """
    source = sys.stdin.read() if file == "-" else Path(file).read_text()
    outcome = service.run(ScriptRequest(
        source=source, tab=tab, extract_mode=mode, read_page=read_page,
        timeout_s=timeout, as_json=json_out))
    _render_script(outcome, json_out)


def _render_script(outcome: service.ScriptOutcome, as_json: bool) -> None:
    """A script that failed exits non-zero; where it failed goes to stderr."""
    match outcome:
        case service.Ran():
            if as_json or outcome.page is None:
                json.dump(outcome.model_dump(mode="json"), sys.stdout, indent=2)
                print()
            else:
                print(f"   tab: {outcome.tab}", file=sys.stderr)
                if outcome.returned is not None:
                    print(f"   returned: {outcome.returned!r}", file=sys.stderr)
                _render(outcome.page, as_json=False)
        case service.Failed():
            print(f"   tab: {outcome.tab}", file=sys.stderr)
            print(f"[{outcome.code}] {outcome.error}", file=sys.stderr)
            if outcome.where:
                print(outcome.where, file=sys.stderr)
            raise SystemExit(2)
        case _ as unreachable:
            assert_never(unreachable)


@app.command
def tabs() -> None:
    """List the open tabs and their ids, for `script --tab`."""
    for page in targets.pages():
        print(f"{page.id}  {page.title[:40]:40}  {page.url}")


@app.command
def open(url: str, *, show: bool = False) -> None:  # noqa: A001
    """Park a URL in a tab, without putting the window on screen.

    Navigating and displaying are separate on purpose: the window should only
    appear when a human is actually needed. Pass --show, or run `show`
    afterwards, when you want to look at it -- to log in, typically.

    Parameters
    ----------
    show
        Also put the browser on screen.
    """
    with browser.Session() as session:
        page = session.page(reuse=False)
        page.goto(url, wait_until=WaitUntil.DOM_CONTENT_LOADED.value, timeout=60000)
        if show:
            print(present.select().present(), file=sys.stderr)
            try:
                page.bring_to_front()
            except Exception:
                pass
    hint = "" if show else " -- run `agent-browser show` to log in there"
    print(f"opened {url}{hint}")


@app.command(name="close-tabs")
def close_tabs_cmd() -> None:
    """Close orphaned tabs, keeping one blank tab alive.

    Tabs outlive the command that opened them by design -- that is what keeps a
    solved challenge warm -- so `open` and interrupted fetches leave them
    behind.
    """
    with browser.Session() as session:
        keep = session.page(reuse=True)
        if keep.url != "about:blank":
            keep.goto("about:blank")
        print(f"closed {session.close_other_tabs(keep=keep)} tab(s)")


@app.command
def serve(*, foreground: bool = False, visible: bool = False) -> None:
    """Start the Chrome daemon.

    Parameters
    ----------
    visible
        Skip hiding; leave the window on screen.
    """
    print(browser.start(detach=not foreground, hidden=not visible))


@app.command
def stop() -> None:
    """Kill the daemon and its compositor."""
    survived = browser.stop()
    print(survived if survived else "stopped")


@app.command
def show() -> None:
    """Put the browser in front of you."""
    presenter = present.select()
    print(f"{presenter.present()} [{presenter.name.value}]")


@app.command
def hide() -> None:
    """Tuck the browser away again."""
    presenter = present.select()
    presenter.dismiss()
    print(f"dismissed [{presenter.name.value}]")


@app.command
def status() -> None:
    """Show daemon, window, and open tabs."""
    launcher = launch.select()
    presenter = present.select()
    up = browser.is_up()
    print(f"daemon:    {'up' if up else 'down'} ({settings.cdp_url})")
    print(f"launch:    {launcher.name.value}")
    print(f"presenter: {presenter.name.value} "
          f"({'showing' if presenter.presented() else 'hidden'})")
    live = session_mod.live()
    host, port = present.endpoint()
    print(f"session:   {'live' if live is not None else 'stale'} "
          f"(vnc {host}:{port})")
    print(f"profile:   {settings.profile_dir}")
    # What the tool can call `blocked` -- a fixed table, so it belongs to no
    # session and needs no command of its own. `agent-browser signatures` was
    # that command, and it existed to curate a learned list that ticket 019
    # removed; printing a constant was all it had left to do. It says the
    # useful half here, where a human already looks when a fetch surprised
    # them, and everything not on this line arrives as ordinary content.
    print("recognises: " + ", ".join(s.name for s in BUILTIN))
    if up:
        with browser.Session() as session:
            for page in session.context.pages:
                print(f"  tab: {page.url[:100]}")


_EXIT_CODES = {
    ErrorCode.PAGE_BLOCKED: 2,
    ErrorCode.HANDOFF_TIMEOUT: 2,
    ErrorCode.DAEMON_NOT_RUNNING: 3,
}


def main() -> None:
    """Single place that turns a domain error into terminal behaviour."""
    try:
        app()
    except AgentBrowserError as error:
        print(f"error: {error.message}", file=sys.stderr)
        if error.detail is not None:
            print(f"       {error.detail}", file=sys.stderr)
        raise SystemExit(_EXIT_CODES.get(error.code, 1))


if __name__ == "__main__":
    main()
