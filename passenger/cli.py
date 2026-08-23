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

from . import (browser, lanes, launch, present, service,
               session as session_mod, targets)
from .config import settings
from .detect import BUILTIN
from .errors import ErrorCode, PassengerError
from .models import ExtractMode, FetchRequest, ScriptRequest, WaitUntil

app = cyclopts.App(
    name="passenger",
    help="Fetch web context through a real, logged-in Chrome, "
         "with a human handoff when a site puts up a challenge.",
)


@app.command
def fetch(
    url: str,
    *,
    mode: Annotated[ExtractMode, cyclopts.Parameter(name=["--mode", "--extract"])],
    lane: str = lanes.CLI,
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
    lane
        Which lane owns the tab. Defaults to the reserved `cli` lane, which is
        what makes `fetch` and then `script --tab` work across two commands
        typed thirty seconds apart -- a minted id would have to be copied by
        hand, and a lane per invocation could not see the previous one's tab.
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
        Close this lane's other tabs afterwards, clearing tabs orphaned by
        earlier runs in it.
    json_out
        Emit a JSON record instead of bare markdown.
    """
    request = FetchRequest(
        url=url,
        lane=lane,
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
    lane: str = lanes.CLI,
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
    lane
        Which lane owns the tab. Defaults to the reserved `cli` lane.
    tab
        Tab id to run against, from `tabs`. Must be a tab this lane owns;
        another lane's is refused exactly as a closed one is. Omitted means a
        fresh blank tab.
    read_page
        With --no-read-page, skip extracting the ending page.
    timeout
        Seconds each Playwright operation inside the script may take.
    """
    source = sys.stdin.read() if file == "-" else Path(file).read_text()
    outcome = service.run(ScriptRequest(
        source=source, lane=lane, tab=tab, extract_mode=mode,
        read_page=read_page, timeout_s=timeout, as_json=json_out))
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
def tabs(*, lane: str = lanes.CLI) -> None:
    """List a lane's tabs and their ids, for `script --tab`.

    Parameters
    ----------
    lane
        Whose tabs to list. `orphan` holds the ones no lane claims -- opened
        by a page itself, or by a human during a handoff.
    """
    lanes.sweep()
    mine = set(lanes.tabs_of(lane))
    for page in targets.pages():
        if page.id in mine:
            print(f"{page.id}  {page.title[:40]:40}  {page.url}")


@app.command
def open(url: str, *, show: bool = False, lane: str = lanes.CLI) -> None:  # noqa: A001
    """Park a URL in a tab, without putting the window on screen.

    Navigating and displaying are separate on purpose: the window should only
    appear when a human is actually needed. Pass --show, or run `show`
    afterwards, when you want to look at it -- to log in, typically.

    Parameters
    ----------
    show
        Also put the browser on screen.
    lane
        Which lane owns the tab.
    """
    lanes.require(lane)
    with browser.Session() as session:
        page = session.page(lane, reuse=False)
        page.goto(url, wait_until=WaitUntil.DOM_CONTENT_LOADED.value, timeout=60000)
        if show:
            lanes.claim_screen(lane)
            print(present.select().present(), file=sys.stderr)
            try:
                page.bring_to_front()
            except Exception:
                pass
    hint = "" if show else " -- run `passenger show` to log in there"
    print(f"opened {url}{hint}")


@app.command(name="close-tabs")
def close_tabs_cmd(tabs: list[str] | None = None, *,
                   lane: str = lanes.CLI) -> None:
    """Close tabs in a lane, keeping the browser alive.

    Tabs outlive the command that opened them by design -- that is what keeps a
    solved challenge warm -- so `open` and interrupted fetches leave them
    behind.

    Parameters
    ----------
    tabs
        Which tabs to close. Omitted means every tab in the lane; on the CLI
        that is a human saying it out loud, where the MCP surface makes it a
        separate verb so an agent cannot ask for it by forgetting an argument.
    lane
        Which lane to close them in. `orphan` for tabs no lane claims.
    """
    lanes.sweep()
    doomed = tuple(tabs) if tabs else lanes.tabs_of(lane)
    print(f"closed {lanes.close_tabs(lane, doomed)} tab(s)")


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
def show(*, lane: str = lanes.CLI) -> None:
    """Put the browser in front of you."""
    lanes.require(lane)
    lanes.claim_screen(lane)
    presenter = present.select()
    print(f"{presenter.present()} [{presenter.name.value}]")


@app.command
def hide(*, lane: str = lanes.CLI, force: bool = False) -> None:
    """Tuck the browser away again, if nobody else is still looking.

    Parameters
    ----------
    force
        Dismiss even while another lane holds a claim. The human's override:
        an agent has no equivalent, because taking the window from somebody
        mid-captcha is the interference lanes exist to stop.
    """
    presenter = present.select()
    last = lanes.release_screen(lane)
    if not last and not force:
        print(f"still shown: {len(lanes.screen_claims())} other claim(s) "
              "-- pass --force to dismiss anyway")
        return
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
    # session and needs no command of its own. `passenger signatures` was
    # that command, and it existed to curate a learned list that ticket 019
    # removed; printing a constant was all it had left to do. It says the
    # useful half here, where a human already looks when a fetch surprised
    # them, and everything not on this line arrives as ordinary content.
    print("recognises: " + ", ".join(s.name for s in BUILTIN))
    if up:
        # A count, not a listing. A lane sees only its own tabs, and that
        # holds for a human at a terminal too -- the alternative was a global
        # view here, and it was rejected: a view that exists gets used, and
        # then the isolation is a convention rather than a property. What is
        # owed instead is a number big enough to notice, so tabs piling up in
        # a lane nobody is watching are at least visible as a total.
        open_tabs, orphaned = lanes.counts()
        print(f"tabs:      {open_tabs} open, {orphaned} orphan")


_EXIT_CODES = {
    ErrorCode.PAGE_BLOCKED: 2,
    ErrorCode.HANDOFF_TIMEOUT: 2,
    ErrorCode.DAEMON_NOT_RUNNING: 3,
}


def main() -> None:
    """Single place that turns a domain error into terminal behaviour."""
    try:
        app()
    except PassengerError as error:
        print(f"error: {error.message}", file=sys.stderr)
        if error.detail is not None:
            print(f"       {error.detail}", file=sys.stderr)
        raise SystemExit(_EXIT_CODES.get(error.code, 1))


if __name__ == "__main__":
    main()
