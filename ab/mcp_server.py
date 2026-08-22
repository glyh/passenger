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

from . import browser, present, registry, service, session as session_mod
from .config import settings
from .models import ExtractMode, FetchRequest, WaitUntil

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
        "try to solve a captcha yourself."
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
    min_words: Annotated[int | None, Field(
        description="Below this word count a page is treated as blocked. "
                    "0 disables that check.")] = None,
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
        min_words=(settings.min_content_words if min_words is None
                   else min_words),
        allow_handoff=wait_seconds > 0,
        handoff_timeout_s=max(wait_seconds, 1),
        reuse_tab=True,
    )
    return service.fetch(request)


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
