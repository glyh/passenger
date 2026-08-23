"""The one fetch orchestration, shared by every frontend.

A blocked page is an *outcome*, not an error: it is the expected, designed-for
result of pointing this tool at a protected site. So it comes back as a value
in a union rather than as a raised exception, and each frontend decides what to
do with it -- the CLI exits 2, the MCP server hands the agent something it can
act on.
"""
from typing import Any, Literal

from pydantic import BaseModel

from . import (browser, handoff, lanes, pictures, probe as probe_mod,
               script, targets)
from .detect import classify
from .errors import HandoffTimeout, ScriptError
from .models import (Blocker,
                     Pictures, ScriptRequest, SignatureKind)


class Measured(BaseModel, frozen=True):
    """What a page measures, which is never what it means.

    Was `Fetched`, and carried `markdown` and `mode_used` until ticket 046
    retired extraction. What is left is what this side can honestly say about a
    page it did not interpret: how much text the browser itself reports, and
    what the page renders that text cannot carry.

    `char_count` is `document.body.innerText`, not the length of an extraction.
    That distinction is the whole of ticket 039, which closed undone on a
    `char_count` of 0 for a page holding 2,647 characters -- a number that
    measured the extractor while looking like it measured the page. There is no
    extractor now, so there is nothing left to lie about.
    """

    type: Literal["measured"] = "measured"
    url: str
    title: str
    char_count: int
    # What the page renders that text cannot carry (ticket 017). Flat rather
    # than nested, because these three sit alongside `char_count` as answers to
    # one question -- how much of this page is actually readable as text.
    largest_image: float = 0.0
    large_images: int = 0
    largest_image_src: str = ""


class Blocked(BaseModel, frozen=True):
    """A signature matched, so a human is genuinely required.

    `evidence` and `proposed_condition` used to ride along: a page that merely
    yielded few words was screenshotted and turned into a candidate rule.
    That path is gone with the word-count tier (ticket 005) -- it was proposing
    to block whole domains by their own name.
    """

    type: Literal["blocked"] = "blocked"
    name: str
    kind: SignatureKind
    url: str
    # The tab the wall is on, so the caller can act on it without guessing.
    # `Ran` and `Failed` always carried one; this did not, which left an agent
    # that wanted to summon a human deliberately reading `list_tabs` and
    # matching on a URL (ticket 018).
    tab: str = ""
    hint: str = ""


PageOutcome = Measured | Blocked


class Ran(BaseModel, frozen=True):
    """A script that finished, and what the tab looked like afterwards."""

    type: Literal["ran"] = "ran"
    tab: str
    returned: Any = None
    page: PageOutcome | None = None


class Failed(BaseModel, frozen=True):
    """A script that did not finish -- bad source, an exception, or a handle.

    An outcome rather than an exception, for the same reason `blocked` is one:
    the caller's next move is to fix the script and call again, and it needs
    the line number and the state of the tab to do that. The tab is left
    exactly where the script left it.
    """

    type: Literal["failed"] = "failed"
    tab: str
    code: str
    error: str
    where: str = ""
    page: PageOutcome | None = None


ScriptOutcome = Ran | Failed


def inspect(page: Any) -> Blocker | None:
    """Is a known vendor's wall on this page?

    The tail every read shares. It used to extract the page as well and hand
    both back; extraction left with `fetch` (ticket 046) and what remains is
    the one judgement this side is still allowed to make -- a match against a
    fixed table of vendors' own markup, which is a measurement because a vendor
    either serves that markup or does not (ticket 038).
    """
    return classify(probe_mod.probe(page))


def run(request: ScriptRequest) -> ScriptOutcome:
    """The passthrough door: caller-supplied code, run against a page.

    Everything this project knows how to do to a page is reachable from here
    without being rewrapped, because what is handed over is `page` itself
    (ticket 004). What this function adds is the envelope: which tab, a bound
    reader, a bounded clock, and the same reading of the ending page that
    `fetch` gives -- so a challenge met halfway through a sequence comes back
    as `blocked`, not as a puzzling empty string.
    """
    lanes.sweep()
    lanes.require(request.lane)
    lanes.touch(request.lane)
    with browser.Session() as session:
        page = session.page_for(request.lane, request.tab)
        # Every Playwright call inside the script inherits this, so a wait on
        # a selector that never appears ends the call instead of the session.
        # A script that loops without calling Playwright is not interruptible;
        # that is the honest limit of running code in-process.
        page.set_default_timeout(request.timeout_s * 1000)
        tab = session.target_id(page)

        try:
            returned = script.execute(request.source, page)
        except ScriptError as failure:
            outcome: ScriptOutcome = Failed(
                tab=tab, code=failure.code.value, error=failure.message,
                where=failure.detail or "", page=_look(page, tab))
        else:
            outcome = Ran(tab=tab, returned=returned, page=_look(page, tab))
        # A script may have opened tabs of its own -- window.open, or a link
        # with target="_blank". Attributing them to the lane that caused them
        # is what keeps them from becoming invisible and uncollectable.
        lanes.reconcile(tuple(session.target_id(open_page)
                              for open_page in session.context.pages),
                        targets.openers())
        lanes.touch(request.lane)
        return outcome


def _look(page: Any, tab: str) -> PageOutcome:
    """What the tab holds now: a wall, or a measurement of the page.

    Always taken, where it used to be skippable with `read_page=False`. That
    switch existed to spare a caller the cost of a full markdown extraction it
    did not want; a measurement is a character count and a picture geometry,
    and nobody needs to opt out of those.
    """
    blocker = inspect(page)
    if blocker is None:
        return _measured(page)
    return _blocked(blocker, tab,
                    "show_browser with this tab and a wait, or `passenger "
                    "show`; solve it, then call again with this same tab -- it "
                    "is still open, and still there")


def _measured(page: Any) -> Measured:
    """Every successful read passes through here, which is why the pictures
    are measured here rather than in `inspect`.

    A script's ending page and the page a human unblocked by hand both build
    their result on this line; measuring one level up would have left the
    handoff path silently unmeasured.
    """
    try:
        title = page.title()
    except Exception:
        title = ""
    try:
        chars = len(page.inner_text("body"))
    except Exception:
        # A renderer that will not answer is not a page of zero characters,
        # and saying so was ticket 039's complaint about the old count.
        chars = 0
    seen: Pictures = pictures.measure(page)
    return Measured(url=page.url, title=title, char_count=chars,
                    largest_image=seen.largest, large_images=seen.count,
                    largest_image_src=seen.src)


def _blocked(blocker: Blocker, tab: str, hint: str) -> Blocked:
    return Blocked(name=blocker.signature.name, kind=blocker.signature.kind,
                   url=blocker.probe.url, tab=tab, hint=hint)
