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
from .extract import extract
from .models import (Blocker, ExtractMode, Extraction, FetchRequest,
                     Pictures, ScriptRequest, SignatureKind)


class Fetched(BaseModel, frozen=True):
    type: Literal["fetched"] = "fetched"
    url: str
    title: str
    mode_used: ExtractMode
    char_count: int
    # What the page renders that the markdown cannot carry (ticket 017). Flat
    # rather than nested, because these three sit alongside `char_count` as
    # answers to one question -- how much of this page did I actually get --
    # and a caller reading a reply should not have to open a sub-object to
    # find out that the answer was in a photograph.
    largest_image: float = 0.0
    large_images: int = 0
    largest_image_src: str = ""
    markdown: str


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


FetchOutcome = Fetched | Blocked


class Ran(BaseModel, frozen=True):
    """A script that finished, and what the tab looked like afterwards."""

    type: Literal["ran"] = "ran"
    tab: str
    returned: Any = None
    page: FetchOutcome | None = None


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
    page: FetchOutcome | None = None


ScriptOutcome = Ran | Failed


def inspect(page: Any,
            extract_mode: ExtractMode) -> tuple[Extraction, Blocker | None]:
    """Read the page and decide whether it counts as content.

    The tail both doors share: `fetch` runs it once after its navigation, and
    a script runs it on whatever page it ends on -- which is what makes a
    challenge that appears at step four come back in the shape the caller
    already handles, with no per-step probing.
    """
    extraction = extract(page, extract_mode)
    return extraction, classify(probe_mod.probe(page))


def fetch(request: FetchRequest) -> FetchOutcome:
    # Sweep *before* the check, not after. A lane that expired between calls
    # passes `require` -- it is still a row -- and is then destroyed by the
    # sweep underneath the call, so the first `adopt` hits a foreign key that
    # no longer resolves and the caller gets a sqlite error instead of
    # LANE_NOT_FOUND. Collect first, then ask, and the answer is honest.
    lanes.sweep()
    lanes.require(request.lane)
    lanes.touch(request.lane)
    with browser.Session() as session:
        page = session.page(request.lane, reuse=request.reuse_tab)
        page.goto(request.url, wait_until=request.wait_until.value, timeout=60000)
        page.wait_for_timeout(request.settle_ms)

        def extractor(target: Any) -> Extraction:
            return extract(target, request.extract_mode)

        extraction, blocker = inspect(page, request.extract_mode)

        outcome: FetchOutcome
        if blocker is None:
            outcome = _fetched(page, extraction)
        else:
            outcome = _resolve(page, blocker, request, extractor,
                               session.target_id(page))

        # A blocked tab is never blanked, whatever `keep_tab` says. It is the
        # one outcome whose tab the caller still needs: the wall is on it, the
        # record now names it, and summoning a human to a tab this side had
        # just navigated away from would hand them a blank page (ticket 018).
        if (not request.keep_tab and outcome.type != "blocked"
                and page.url != "about:blank"):
            page.goto("about:blank")
        if request.close_tabs:
            session.close_others(request.lane, keep=page)
        # On return as well as on entry: a fetch that waited out a handoff can
        # outlast the lane's whole TTL, and expiring underneath itself would
        # close the tab it is about to hand back.
        lanes.touch(request.lane)
        return outcome


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

        def read(target: Any) -> str:
            """The project's own extraction, bound into the script's scope."""
            return extract(target, request.extract_mode).text

        try:
            returned = script.execute(request.source, page, read)
        except ScriptError as failure:
            outcome: ScriptOutcome = Failed(
                tab=tab, code=failure.code.value, error=failure.message,
                where=failure.detail or "", page=_look(page, request, tab))
        else:
            outcome = Ran(tab=tab, returned=returned,
                          page=_look(page, request, tab))
        # A script may have opened tabs of its own -- window.open, or a link
        # with target="_blank". Attributing them to the lane that caused them
        # is what keeps them from becoming invisible and uncollectable.
        lanes.reconcile(tuple(session.target_id(open_page)
                              for open_page in session.context.pages),
                        targets.openers())
        lanes.touch(request.lane)
        return outcome


def _look(page: Any, request: ScriptRequest, tab: str) -> FetchOutcome | None:
    """What the tab holds now, in the shape `fetch` returns -- if asked."""
    if not request.read_page:
        return None
    extraction, blocker = inspect(page, request.extract_mode)
    if blocker is None:
        return _fetched(page, extraction)
    return _blocked(blocker, tab,
                    "show_browser with this tab and a wait, or `passenger "
                    "show`; solve it, then call again with this same tab -- it "
                    "is still open, and still there")


def _fetched(page: Any, extraction: Extraction) -> Fetched:
    """Every successful read passes through here, which is why the pictures
    are measured here rather than in `inspect`.

    `fetch`, a script's ending page, and the page a human unblocked by hand
    all build their result on this line; measuring one level up would have
    left the handoff path silently unmeasured.
    """
    try:
        title = page.title()
    except Exception:
        title = ""
    seen: Pictures = pictures.measure(page)
    return Fetched(url=page.url, title=title, mode_used=extraction.mode_used,
                   char_count=extraction.char_count,
                   largest_image=seen.largest, large_images=seen.count,
                   largest_image_src=seen.src, markdown=extraction.text)


def _resolve(page: Any, blocker: Blocker, request: FetchRequest,
             extractor: handoff.Extractor, tab: str) -> FetchOutcome:
    """Either wait for a human or report the block.

    Reached only on a signature match now. That is what makes presenting the
    window the right response rather than an intrusion: something specific and
    positive said a human is required, instead of a word count saying the page
    was short (ticket 010).
    """
    if request.allow_handoff:
        try:
            extraction = handoff.wait_for_human(
                page, blocker, extractor, request.handoff_timeout_s)
            return _fetched(page, extraction)
        except HandoffTimeout as timeout:
            return _blocked(blocker, tab,
                            f"nobody solved it within {timeout.seconds}s")
    return _blocked(blocker, tab,
                    "show_browser with this tab and a wait, or `passenger "
                    "show`; solve it, then fetch again -- the profile keeps "
                    "the result")


def _blocked(blocker: Blocker, tab: str, hint: str) -> Blocked:
    return Blocked(name=blocker.signature.name, kind=blocker.signature.kind,
                   url=blocker.probe.url, tab=tab, hint=hint)
