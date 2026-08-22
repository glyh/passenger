"""The CLI boundary.

cyclopts lives here and nowhere else: core modules raise domain errors and
return models, and this is the single place that decides what a failure looks
like on a terminal.
"""
import json
import sys
from typing import Annotated, Any

import cyclopts

from . import browser, handoff, launch, present, probe as probe_mod, registry
from .config import settings
from .detect import blocker_name, classify, is_novel
from .errors import AgentBrowserError, BlockedError, ErrorCode
from .extract import extract
from .models import (Blocker, ExtractMode, Extraction, FetchRequest, Signature,
                     WaitUntil)

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
    )
    _render(_run_fetch(request), request)


def _run_fetch(request: FetchRequest) -> Extraction:
    with browser.Session() as session:
        page = session.page(reuse=request.reuse_tab)
        page.goto(request.url, wait_until=request.wait_until.value, timeout=60000)
        page.wait_for_timeout(request.settle_ms)

        def extractor(target: Any) -> Extraction:
            return extract(target, request.extract_mode)

        extraction = extractor(page)
        signatures = registry.active()
        page_probe = probe_mod.probe(page, extraction, signatures)
        blocker = classify(page_probe, signatures, request.min_words)

        if blocker is not None:
            extraction = _handle_blocker(page, blocker, request, extractor)
        if not request.keep_tab and page.url != "about:blank":
            page.goto("about:blank")
        if request.close_tabs:
            closed = session.close_other_tabs(keep=page)
            print(f"closed {closed} other tab(s)", file=sys.stderr)
        return extraction


def _handle_blocker(page: Any, blocker: Blocker, request: FetchRequest,
                    extractor: handoff.Extractor) -> Extraction:
    if is_novel(blocker):
        evidence, proposal = handoff.record_novel(page, blocker)
        print(f"   novel blocker -- evidence: {evidence.screenshot}",
              file=sys.stderr)
        if proposal is not None:
            print(f"   proposed signature: {proposal.condition} (pending review)",
                  file=sys.stderr)
    if not request.allow_handoff:
        raise BlockedError(blocker_name(blocker), blocker.probe.url)
    return handoff.wait_for_human(page, blocker, extractor, request.min_words,
                                  settings.handoff_timeout_s)


def _render(extraction: Extraction, request: FetchRequest) -> None:
    if request.as_json:
        json.dump({"url": request.url, "mode": extraction.mode_used.value,
                   "words": extraction.word_count, "markdown": extraction.text},
                  sys.stdout, indent=2)
        print()
    else:
        print(extraction.text)


@app.command
def open(url: str) -> None:  # noqa: A001 -- the verb the user reaches for
    """Open a URL in the visible window so you can log in by hand."""
    with browser.Session() as session:
        page = session.page(reuse=False)
        page.goto(url, wait_until=WaitUntil.DOM_CONTENT_LOADED.value, timeout=60000)
        print(present.select().present(), file=sys.stderr)
        try:
            page.bring_to_front()
        except Exception:
            pass
    print(f"opened {url} -- log in there; the profile keeps the session.")


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
