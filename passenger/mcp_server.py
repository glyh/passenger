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

The docstrings here carry the *call contract* and nothing else. Operating
knowledge -- what `blocked` misses, how to recognise a wall, that a read is one
screen, how to read a page at all -- lives in the `using-passenger` skill,
shipped from this repo under `skills/`. It used to live here too, and six
skills in the owner's notes had hand-copied it by the time anyone noticed;
ticket 032 found that a docstring and these instructions arrive on the same
event, so a second copy here buys nothing and drifts.

That division got sharper with ticket 046: extraction left this codebase
entirely, so the *recipes* for reading a page -- including `walker.js` itself
-- are in the skill directory rather than here. There is one door now, and it
hands over `page`.
"""
from typing import Annotated

from mcp.server import MCPServer
from pydantic import Field

from . import (browser, handoff, lanes, notify, present, service,
               session as session_mod, targets)
from .config import settings
from .models import ScriptRequest, WaitFor

server = MCPServer(
    name="passenger",
    instructions=(
        "Reach web pages through a real, logged-in Chrome that sites cannot "
        "distinguish from an ordinary browser. Use this instead of a plain "
        "HTTP fetch when a page needs a login, is behind anti-bot protection, "
        "or renders its content with JavaScript.\n\n"
        "Call `open_lane` first: every tab you open lives in your lane, and "
        "no other caller can see or close it.\n\n"
        "`script` is the only door onto a page: it navigates, drives and hands "
        "back what you return. This server does not interpret pages -- there "
        "is no extraction here, and reading one is yours to write.\n\n"
        "How to operate it -- the recipes for reading a page, what `blocked` "
        "does and does not catch, recognising a wall it cannot name, why a "
        "read is only the first screen, and why reading beats driving -- is "
        "the `using-passenger` skill. Load it before the first call."
    ),
)


def _ensure_daemon() -> None:
    if not browser.is_up():
        browser.start(detach=True, hidden=True)


def _housekeep(lane: str | None = None) -> None:
    """Collect expired lanes, then check the caller's is still one of them.

    Order matters: a lane that expired between calls is still a row until the
    sweep reaches it, so checking first would let a doomed lane through and
    fail later on a dangling foreign key rather than saying LANE_NOT_FOUND.

    A lane holding the screen when its clock runs out takes its claim with it,
    and nothing else would then put the viewer away -- so the sweep that frees
    the last claim is also what dismisses it.
    """
    holders = set(lanes.screen_claims())
    if holders & set(lanes.sweep()) and not lanes.screen_claims():
        present.select().dismiss()
    if lane is not None:
        lanes.require(lane)


@server.tool()
def script(
    source: Annotated[str, Field(description=(
        "Python, run with `page` (a Playwright page) in scope. Use `return` "
        "to hand a value back; it must be JSON, so return text or a list, "
        "never a locator. To just read a page: "
        "page.goto(url); return page.inner_text('body'). For markdown with "
        "links and headings, paste the walker recipe from the "
        "`using-passenger` skill."))],
    lane: Annotated[str, Field(description=(
        "Your lane, from open_lane. Tabs opened here are yours: no other "
        "caller sees them, and none can close them."))],
    tab: Annotated[str | None, Field(description=(
        "Which tab to run against, from a previous reply or from list_tabs. "
        "Omit for a fresh blank tab."))] = None,
    timeout_seconds: Annotated[int, Field(
        description="Per-call budget for each Playwright operation.",
        ge=1, le=600)] = 60,
) -> service.ScriptOutcome:
    """Open a page, drive it, and read it -- the only door onto the browser.

    Navigation, interaction and reading are all this call: `page.goto(url)`
    then whatever you need. The reply carries what you returned, plus a
    measurement of the tab you ended on -- its character count and pictures, or
    a `blocked` record if a known vendor's wall is in the way.

    This tool does not interpret pages. Extraction is yours to write, and the
    `using-passenger` skill carries the recipes.

    The tab stays open and comes back in `tab`, so a sequence continues across
    calls.
    """
    _ensure_daemon()
    return service.run(ScriptRequest(
        source=source, lane=lane, tab=tab, timeout_s=timeout_seconds))


@server.tool()
def open_lane() -> str:
    """Open a lane and return its id. Call this before anything else.

    A lane owns the tabs opened in it. Nothing outside it can see or close
    them, and nothing it does reaches another caller's tabs. It collects
    itself after 30 minutes of no calls, closing its tabs -- `set_ttl` when
    you know you will be waiting longer than that.
    """
    _ensure_daemon()
    _housekeep()
    return lanes.open_lane()


@server.tool()
def set_ttl(
    lane: Annotated[str, Field(description="The lane, from open_lane.")],
    minutes: Annotated[int, Field(
        description="Quiet time before this lane and its tabs are collected.",
        ge=1, le=1440)],
) -> str:
    """Change how long this lane may sit idle before it is collected.

    Every call naming the lane restarts its clock, so this is for waits you
    are about to start rather than for work in progress -- asking a human for
    something slow, most often.
    """
    _housekeep(lane)
    lanes.set_ttl(lane, minutes * 60)
    return f"lane {lane} expires after {minutes} min of quiet"


@server.tool()
def list_tabs(
    lane: Annotated[str, Field(description=(
        "Whose tabs to list. Your own lane, or 'orphan' for tabs no lane "
        "claims -- what a page opened by itself, or a human opened during a "
        "handoff."))],
) -> list[dict[str, str]]:
    """List the tabs in a lane, so a script can be pointed at one of them."""
    _ensure_daemon()
    _housekeep(lane)
    lanes.touch(lane)
    mine = set(lanes.tabs_of(lane))
    return [{"tab": page.id, "url": page.url, "title": page.title}
            for page in targets.pages() if page.id in mine]


@server.tool()
def close_tabs(
    lane: Annotated[str, Field(description="The lane the tabs are in.")],
    tabs: Annotated[list[str], Field(description=(
        "Which tabs to close, from list_tabs or a previous reply. Naming them "
        "is required: closing is not something to ask for by omission."))],
) -> str:
    """Close the tabs you name, keeping the session and every other tab alive."""
    _ensure_daemon()
    _housekeep(lane)
    lanes.touch(lane)
    return f"closed {lanes.close_tabs(lane, tuple(tabs))} tab(s)"


@server.tool()
def close_all_tabs(
    lane: Annotated[str, Field(description="The lane to empty.")],
) -> str:
    """Close every tab in this lane. The lane stays open and reusable."""
    _ensure_daemon()
    _housekeep(lane)
    lanes.touch(lane)
    return f"closed {lanes.close_tabs(lane, lanes.tabs_of(lane))} tab(s)"


@server.tool()
def destroy_lane(
    lane: Annotated[str, Field(description="The lane to end.")],
) -> str:
    """Close this lane's tabs and end the lane. The id stops working.

    Say this when you are done, rather than leaving tabs parked until the TTL
    reaches them.
    """
    _ensure_daemon()
    _housekeep(lane)
    closed = lanes.close_tabs(lane, lanes.tabs_of(lane))
    lanes.destroy(lane)
    return f"closed {closed} tab(s), lane {lane} is gone"


@server.tool()
def show_browser(
    lane: Annotated[str, Field(description=(
        "Your lane. It holds a claim on the screen until you call "
        "hide_browser, so another caller finishing its work cannot take the "
        "window away from the person you just asked for help."))],
    tab: Annotated[str | None, Field(description=(
        "Bring this tab to the front first, from a previous reply or from "
        "list_tabs, so the human lands on the page you mean."))] = None,
    wait_seconds: Annotated[int, Field(
        description="Block for up to this long. 0 (default) returns as soon "
                    "as it is on screen.",
        ge=0, le=900)] = 0,
    until: Annotated[WaitFor, Field(
        description="What ends the wait. `closed` (default) waits for the "
                    "human to close the viewer, which is a fact about the "
                    "human. `unblocked` waits for the vendor's wall to stop "
                    "matching on `tab`, which is a fact about the page -- "
                    "stronger, but it needs a tab and only sees walls this "
                    "tool can name.")] = WaitFor.CLOSED,
    notify_human: Annotated[bool, Field(
        description="Send a desktop notification or webhook. Set this when "
                    "the human is not watching this conversation -- running "
                    "unattended, or on a machine they are not sitting at.")]
        = False,
    ttl_minutes: Annotated[int | None, Field(
        description="Raise the lane's idle timeout for this handoff. A human "
                    "who wanders off for longer than the lane's TTL comes "
                    "back to a tab that was collected.",
        ge=1, le=1440)] = None,
) -> str:
    """Put the browser on screen so the user can log in or solve a challenge.

    Also how you ask for a human deliberately, not only in answer to a
    `blocked` reply.

    By default nothing here inspects the page -- the wait ends when the human
    closes the viewer, and the reply says so. `until="unblocked"` is the other
    reading: it polls the named tab until the wall stops matching. That was
    `fetch(wait_seconds=...)` before ticket 046 retired it, and it is a
    measurement rather than a guess only because the signature table is fixed.
    Whichever you wait on, read the tab afterwards and judge for yourself.
    """
    _ensure_daemon()
    _housekeep(lane)
    if ttl_minutes is not None:
        lanes.set_ttl(lane, ttl_minutes * 60)
    lanes.touch(lane)
    lanes.claim_screen(lane)
    if tab is not None:
        with browser.Session() as session:
            handoff.bring_to_front(session.page_for(lane, tab))
    presenter = present.select()
    how = presenter.present()
    if notify_human:
        notify.select().notify("Agent browser needs you", how)
    if wait_seconds == 0:
        lanes.touch(lane)
        return how
    if until is WaitFor.UNBLOCKED:
        if tab is None:
            lanes.touch(lane)
            return f"{how} -- cannot wait on a wall with no tab named"
        with browser.Session() as session:
            waited = handoff.wait_until_unblocked(
                session.page_for(lane, tab), wait_seconds)
    else:
        waited = handoff.wait_for_dismissal(presenter, wait_seconds)
    lanes.touch(lane)
    return f"{how} -- {waited}"


@server.tool()
def hide_browser(
    lane: Annotated[str, Field(description=(
        "The lane releasing the screen. The viewer stays up while any other "
        "lane still holds a claim."))],
) -> str:
    """Release your claim on the screen, tucking the browser away if you were
    the last one holding it."""
    lanes.require(lane)
    lanes.touch(lane)
    if not lanes.release_screen(lane):
        return f"still shown: {len(lanes.screen_claims())} other claim(s)"
    present.select().dismiss()
    return "dismissed"


@server.tool()
def browser_status() -> dict[str, str]:
    """Report whether the browser is running, and what is on screen."""
    presenter = present.select()
    live = session_mod.live()
    host, port = present.endpoint()
    open_tabs, orphaned = lanes.counts()
    return {
        "daemon": "up" if browser.is_up() else "down",
        "presenter": presenter.name.value,
        "on_screen": str(presenter.presented()),
        "profile": str(settings.profile_dir),
        # Named so a black screen is diagnosable: a viewer attached while
        # session reads "stale" is looking at a compositor with nothing in it.
        "session": "live" if live is not None else "stale",
        "vnc": f"{host}:{port}",
        # The only number that reveals a lane you do not own. Without it
        # nothing in this tool can show tabs piling up, since every listing is
        # scoped to the caller. A count, deliberately: ids and owners would be
        # a listing, and a lane's tabs are nobody else's business.
        "tabs": f"{open_tabs} open, {orphaned} orphan",
        "screen_claims": str(len(lanes.screen_claims())),
    }


def main() -> None:
    server.run()


if __name__ == "__main__":
    main()
