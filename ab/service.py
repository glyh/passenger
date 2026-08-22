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

from . import browser, handoff, probe as probe_mod, registry
from .detect import blocker_name, classify, is_novel
from .errors import HandoffTimeout
from .extract import extract
from .models import Blocker, ExtractMode, Extraction, FetchRequest, SignatureKind


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


def fetch(request: FetchRequest) -> FetchOutcome:
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
    evidence_path: Path | None = None
    proposed: str | None = None
    if is_novel(blocker):
        # Runs whether or not a handoff follows: a suppressed handoff is
        # exactly when you most want to know what you hit.
        evidence, proposal = handoff.record_novel(page, blocker)
        evidence_path = evidence.screenshot
        proposed = proposal.condition if proposal is not None else None

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


def _blocked(blocker: Blocker, evidence: Path | None, proposed: str | None,
             hint: str) -> Blocked:
    kind = (blocker.signature.kind if blocker.type == "known"
            else SignatureKind.UNKNOWN)
    return Blocked(name=blocker_name(blocker), kind=kind, url=blocker.probe.url,
                   evidence=evidence, proposed_condition=proposed, hint=hint)
