"""The CLI boundary.

cyclopts lives here and nowhere else: core modules raise domain errors and
return models, and this is the single place that decides what a failure looks
like on a terminal.
"""
import json
import sys
from typing import Annotated, assert_never

import cyclopts

from . import browser, launch, present, registry, service, session as session_mod
from .config import settings
from .errors import AgentBrowserError, ErrorCode
from .models import ExtractMode, FetchRequest, WaitUntil

app = cyclopts.App(
    name="agent-browser",
    help="Fetch web context through a real, logged-in Chrome, "
         "with a human handoff when a site puts up a challenge.",
)


@app.command
def fetch(
    url: str,
    *,
    mode: Annotated[ExtractMode, cyclopts.Parameter(name=["--mode", "--extract"])]
        = ExtractMode.AUTO,
    dom: bool = False,
    wait: WaitUntil = WaitUntil.DOM_CONTENT_LOADED,
    settle: int = 1500,
    min_words: int | None = None,
    handoff_enabled: Annotated[bool, cyclopts.Parameter(name=["--handoff"])] = True,
    new_tab: bool = False,
    keep_tab: bool = False,
    close_tabs: bool = False,
    json_out: Annotated[bool, cyclopts.Parameter(name=["--json"])] = False,
) -> None:
    """Fetch a URL and print its content.

    Parameters
    ----------
    url
        Page to fetch.
    mode
        auto measures both extractors and picks; article suits documents,
        dom suits JS apps.
    dom
        Shorthand for --mode dom.
    settle
        Milliseconds to let client-side rendering finish.
    min_words
        Below this, a page is treated as blocked. 0 disables tier-2 detection.
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
        extract_mode=ExtractMode.DOM if dom else mode,
        wait_until=wait,
        settle_ms=settle,
        min_words=settings.min_content_words if min_words is None else min_words,
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
            if outcome.evidence is not None:
                print(f"   evidence: {outcome.evidence}", file=sys.stderr)
            if outcome.proposed_condition is not None:
                print(f"   proposed signature: {outcome.proposed_condition} "
                      f"(pending review)", file=sys.stderr)
            json.dump(outcome.model_dump(mode="json"), sys.stderr, indent=2)
            print(file=sys.stderr)
            raise SystemExit(2)
        case _ as unreachable:
            assert_never(unreachable)


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
    browser.stop()
    print("stopped")


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
    if up:
        with browser.Session() as session:
            for page in session.context.pages:
                print(f"  tab: {page.url[:100]}")


@app.command
def signatures(*, approve: str | None = None, forget: str | None = None) -> None:
    """List learned blocker signatures, or curate them.

    Parameters
    ----------
    approve
        Promote a pending signature so it is allowed to match.
    forget
        Delete a signature by name.
    """
    if approve is not None:
        print(f"approved {registry.approve(approve).name}")
        return
    if forget is not None:
        registry.forget(forget)
        print(f"forgot {forget}")
        return
    for signature in registry.listing():
        flag = " (pending review)" if signature.pending_review else ""
        print(f"{signature.name:<40} {signature.kind.value:<10} "
              f"{signature.condition}{flag}")


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
