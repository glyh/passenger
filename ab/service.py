"""The one fetch orchestration, shared by every frontend.

A blocked page is an *outcome*, not an error: it is the expected, designed-for
result of pointing this tool at a protected site. So it comes back as a value
in a union rather than as a raised exception, and each frontend decides what to
do with it -- the CLI exits 2, the MCP server hands the agent something it can
act on.
"""
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel

from . import browser, handoff, probe as probe_mod, registry, script
from .detect import blocker_name, classify, is_novel
from .errors import HandoffTimeout, ScriptError
from .extract import extract
from .models import (Blocker, ExtractMode, Extraction, FetchRequest,
                     ScriptRequest, SignatureKind)


class Fetched(BaseModel, frozen=True):
    type: Literal["fetched"] = "fetched"
    url: str
    title: str
    mode_used: ExtractMode
    word_count: int
    markdown: str


class Blocked(BaseModel, frozen=True):
    type: Literal["blocked"] = "blocked"
    name: str
    kind: SignatureKind
    url: str
    evidence: Path | None = None
    proposed_condition: str | None = None
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


def inspect(page: Any, extract_mode: ExtractMode,
            min_words: int) -> tuple[Extraction, Blocker | None]:
    """Read the page and decide whether it counts as content.

    The tail both doors share: `fetch` runs it once after its navigation, and
    a script runs it on whatever page it ends on -- which is what makes a
    challenge that appears at step four come back in the shape the caller
    already handles, with no per-step probing.
    """
    extraction = extract(page, extract_mode)
    signatures = registry.active()
    page_probe = probe_mod.probe(page, extraction, signatures)
    return extraction, classify(page_probe, signatures, min_words)


def fetch(request: FetchRequest) -> FetchOutcome:
    with browser.Session() as session:
        page = session.page(reuse=request.reuse_tab)
        page.goto(request.url, wait_until=request.wait_until.value, timeout=60000)
        page.wait_for_timeout(request.settle_ms)

        def extractor(target: Any) -> Extraction:
            return extract(target, request.extract_mode)

        extraction, blocker = inspect(page, request.extract_mode,
                                      request.min_words)

        outcome: FetchOutcome
        if blocker is None:
            outcome = _fetched(page, extraction)
        else:
            outcome = _resolve(page, blocker, request, extractor)

        if not request.keep_tab and page.url != "about:blank":
            page.goto("about:blank")
        if request.close_tabs:
            session.close_other_tabs(keep=page)
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
    with browser.Session() as session:
        page = session.page_for(request.tab)
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
            return Failed(tab=tab, code=failure.code.value,
                          error=failure.message, where=failure.detail or "",
                          page=_look(page, request))
        return Ran(tab=tab, returned=returned, page=_look(page, request))


def _look(page: Any, request: ScriptRequest) -> FetchOutcome | None:
    """What the tab holds now, in the shape `fetch` returns -- if asked."""
    if not request.read_page:
        return None
    extraction, blocker = inspect(page, request.extract_mode, request.min_words)
    if blocker is None:
        return _fetched(page, extraction)
    evidence, proposed = _note_novel(page, blocker)
    return _blocked(blocker, evidence, proposed,
                    "run `agent-browser show`, solve it, then call again "
                    "with this same tab -- it is still open, and still there")


def _fetched(page: Any, extraction: Extraction) -> Fetched:
    try:
        title = page.title()
    except Exception:
        title = ""
    return Fetched(url=page.url, title=title, mode_used=extraction.mode_used,
                   word_count=extraction.word_count, markdown=extraction.text)


def _resolve(page: Any, blocker: Blocker, request: FetchRequest,
             extractor: handoff.Extractor) -> FetchOutcome:
    """Capture evidence, then either wait for a human or report the block."""
    evidence_path, proposed = _note_novel(page, blocker)

    if request.allow_handoff:
        try:
            extraction = handoff.wait_for_human(
                page, blocker, extractor, request.min_words,
                request.handoff_timeout_s)
            return _fetched(page, extraction)
        except HandoffTimeout as timeout:
            return _blocked(blocker, evidence_path, proposed,
                            f"nobody solved it within {timeout.seconds}s")
    return _blocked(blocker, evidence_path, proposed,
                    "run `agent-browser show`, solve it, then fetch again -- "
                    "the profile keeps the result")


def _note_novel(page: Any, blocker: Blocker) -> tuple[Path | None, str | None]:
    """Capture what an unrecognised blocker looked like, and propose a rule.

    Runs whether or not a handoff follows: a suppressed handoff is exactly
    when you most want to know what you hit.
    """
    if not is_novel(blocker):
        return None, None
    evidence, proposal = handoff.record_novel(page, blocker)
    return (evidence.screenshot,
            proposal.condition if proposal is not None else None)


def _blocked(blocker: Blocker, evidence: Path | None, proposed: str | None,
             hint: str) -> Blocked:
    kind = (blocker.signature.kind if blocker.type == "known"
            else SignatureKind.UNKNOWN)
    return Blocked(name=blocker_name(blocker), kind=kind, url=blocker.probe.url,
                   evidence=evidence, proposed_condition=proposed, hint=hint)
