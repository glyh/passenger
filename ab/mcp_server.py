"""MCP frontend.

The second consumer of service.fetch, alongside the CLI. Two differences shape
the tool design:

1. Handoff does not block by default. A tool call that hangs for five minutes
   while someone finds a captcha is a bad citizen, so `fetch` returns the
   `blocked` outcome immediately and the agent decides what to do -- typically
   ask the user, then call again once they've solved it. `wait_seconds` opts
   into blocking when the caller really wants it.

2. The daemon starts on demand. A human runs `serve` first; an agent should
   not have to know that.
"""
from typing import Annotated

from mcp.server import MCPServer
from pydantic import Field

from . import browser, present, registry, service, session as session_mod, targets
from .config import settings
from .models import ExtractMode, FetchRequest, ScriptRequest, WaitUntil

server = MCPServer(
    name="agent-browser",
    instructions=(
        "Fetch web pages through a real, logged-in Chrome that sites cannot "
        "distinguish from an ordinary browser. Use this instead of a plain "
        "HTTP fetch when a page needs a login, is behind anti-bot protection, "
        "or renders its content with JavaScript.\n\n"
        "If a fetch returns type='blocked', a human must solve a challenge: "
        "tell the user what is blocking, ask them to run `agent-browser show` "
        "(or open the noVNC URL) and solve it, then call fetch again. Never "
        "try to solve a captcha yourself.\n\n"
        "For anything a plain fetch cannot reach -- a search box, a tab, the "
        "next page of a list -- use `script`, which runs Playwright code "
        "against a real tab. Prefer reading over driving: after a human has "
        "navigated, `script` with the tab they used costs nothing and is "
        "invisible to the site, whereas synthetic clicks and fills have no "
        "cursor path and no keystroke timing, which is what behavioural "
        "anti-bot systems score. Driving spends the reputation of a session "
        "whose value is that it has never done anything unusual."
    ),
)


def _ensure_daemon() -> None:
    if not browser.is_up():
        browser.start(detach=True, hidden=True)


@server.tool()
def fetch(
    url: Annotated[str, Field(description="Page to fetch.")],
    mode: Annotated[ExtractMode, Field(
        description="auto measures both extractors and picks; article suits "
                    "documents, dom suits JS apps.")] = ExtractMode.AUTO,
    settle_ms: Annotated[int, Field(
        description="Milliseconds to let client-side rendering finish.",
        ge=0, le=30000)] = 1500,
    wait_seconds: Annotated[int, Field(
        description="Block for up to this long waiting for a human to solve a "
                    "challenge. 0 (default) returns immediately instead.",
        ge=0, le=900)] = 0,
) -> service.FetchOutcome:
    """Fetch a URL as markdown through the real browser session.

    Returns either the page content, or a 'blocked' record naming what is in
    the way and how a human can clear it.
    """
    _ensure_daemon()
    request = FetchRequest(
        url=url,
        extract_mode=mode,
        wait_until=WaitUntil.DOM_CONTENT_LOADED,
        settle_ms=settle_ms,
        allow_handoff=wait_seconds > 0,
        handoff_timeout_s=max(wait_seconds, 1),
        reuse_tab=True,
    )
    return service.fetch(request)


@server.tool()
def script(
    source: Annotated[str, Field(description=(
        "Python, run with `page` (a Playwright page) and `read(page)` (this "
        "tool's markdown extraction) in scope. Use `return` to hand a value "
        "back; it must be JSON, so return page.url or read(page), never a "
        "locator. Example: page.fill('#q', 'x'); page.press('#q', 'Enter'); "
        "page.wait_for_selector('.result'); return read(page)"))],
    tab: Annotated[str | None, Field(description=(
        "Which tab to run against, from a previous reply or from list_tabs. "
        "Omit for a fresh blank tab."))] = None,
    mode: Annotated[ExtractMode, Field(
        description="How read(page) and the page report extract content.")]
        = ExtractMode.AUTO,
    read_page: Annotated[bool, Field(description=(
        "Whether the reply carries the ending page as markdown. Turn it off "
        "for steps whose content you do not need -- paging a listing, say."))]
        = True,
    timeout_seconds: Annotated[int, Field(
        description="Per-call budget for each Playwright operation.",
        ge=1, le=600)] = 60,
) -> service.ScriptOutcome:
    """Run Playwright code against a real tab, and read where it ends up.

    The way to reach content that sits behind an interaction, and the way to
    read a page a human navigated to during a handoff. The tab stays open and
    comes back in `tab`, so a sequence continues across calls.
    """
    _ensure_daemon()
    return service.run(ScriptRequest(
        source=source, tab=tab, extract_mode=mode, read_page=read_page,
        timeout_s=timeout_seconds))


@server.tool()
def list_tabs() -> list[dict[str, str]]:
    """List the open tabs, so a script can be pointed at one of them."""
    _ensure_daemon()
    return [{"tab": page.id, "url": page.url, "title": page.title}
            for page in targets.pages()]


@server.tool()
def show_browser() -> str:
    """Put the browser on screen so the user can log in or solve a challenge."""
    _ensure_daemon()
    return present.select().present()


@server.tool()
def hide_browser() -> str:
    """Tuck the browser away again once the user is done."""
    present.select().dismiss()
    return "dismissed"


@server.tool()
def browser_status() -> dict[str, str]:
    """Report whether the browser is running, and what is on screen."""
    presenter = present.select()
    live = session_mod.live()
    host, port = present.endpoint()
    return {
        "daemon": "up" if browser.is_up() else "down",
        "presenter": presenter.name.value,
        "on_screen": str(presenter.presented()),
        "profile": str(settings.profile_dir),
        # Named so a black screen is diagnosable: a viewer attached while
        # session reads "stale" is looking at a compositor with nothing in it.
        "session": "live" if live is not None else "stale",
        "vnc": f"{host}:{port}",
    }


@server.tool()
def close_tabs() -> str:
    """Close tabs left behind by earlier fetches, keeping the session alive."""
    _ensure_daemon()
    with browser.Session() as session:
        keep = session.page(reuse=True)
        if keep.url != "about:blank":
            keep.goto("about:blank")
        return f"closed {session.close_other_tabs(keep=keep)} tab(s)"


@server.tool()
def list_blockers() -> list[dict[str, str]]:
    """List known challenge signatures, including unapproved proposals."""
    return [{"name": s.name, "kind": s.kind.value, "condition": s.condition,
             "pending_review": str(s.pending_review)}
            for s in registry.listing()]


def main() -> None:
    server.run()


if __name__ == "__main__":
    main()
