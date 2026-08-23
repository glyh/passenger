"""Domain models.

Every shape that crosses a boundary -- the signature registry on disk, what we
measured about a page, what the CLI asked for -- is parsed into one of these
once, at the edge. Nothing downstream sees a raw dict.
"""
from enum import Enum
from pathlib import Path

from pydantic import BaseModel, Field, model_validator

from .text import count_words, unlinked


class SignatureKind(str, Enum):
    CHALLENGE = "challenge"
    LOGIN = "login"
    UNKNOWN = "unknown"


class ExtractMode(str, Enum):
    """Which extractor reads the page. There is no `auto`.

    There was, and it measured both extractions and picked by their word
    ratio. Ticket 011 established that the choice depends on the page's
    *type* -- document, listing, profile -- which is not in the two blobs of
    text a comparison is handed, so every signal it computed was a proxy for
    something it could not measure. Ticket 021 removed it rather than tuning
    it, and did not replace it with a default: the caller knows what it
    pointed at, and a tool that guesses silently is worse than one that asks.
    """

    ARTICLE = "article"
    DOM = "dom"


class WaitUntil(str, Enum):
    LOAD = "load"
    DOM_CONTENT_LOADED = "domcontentloaded"
    NETWORK_IDLE = "networkidle"
    COMMIT = "commit"


class BackendName(str, Enum):
    """How Chrome is launched."""

    NESTED = "nested"
    NONE = "none"


class PresenterName(str, Enum):
    """How a human is given a look at the hidden browser."""

    LOCAL = "local"
    WEB = "web"
    NONE = "none"


class Signature(BaseModel, frozen=True):
    """A rule for recognising a blocked page.

    At least one condition is required. The old dict version could produce a
    condition-less signature that silently matched nothing; making it a
    construction-time invariant means that shape can no longer exist.
    """

    name: str
    kind: SignatureKind = SignatureKind.CHALLENGE
    title_re: str | None = None
    url_re: str | None = None
    selector: str | None = None
    pending_review: bool = False
    seen_at: str | None = None
    evidence: Path | None = None

    @model_validator(mode="after")
    def _needs_a_condition(self) -> "Signature":
        if self.title_re is None and self.url_re is None and self.selector is None:
            raise ValueError(f"signature {self.name!r} has no condition")
        return self

    @property
    def condition(self) -> str:
        """Single-line rendering of what this matches on, for listings."""
        return self.selector or self.title_re or self.url_re or "?"


class Target(BaseModel, frozen=True, populate_by_name=True):
    """One entry from Chrome's target list, as the CDP HTTP endpoint reports it.

    That endpoint is served by the browser process, so it keeps answering when
    a page's renderer does not. This shape exists for exactly that moment.
    """

    id: str
    type: str
    url: str
    title: str = ""
    websocket_url: str = Field(default="", alias="webSocketDebuggerUrl")

    @property
    def is_page(self) -> bool:
        """Tabs only. Chrome also lists its own UI, workers and extensions."""
        return self.type == "page"


class PageProbe(BaseModel, frozen=True):
    """What the shell measured about a loaded page.

    Selector evaluation needs the live page, so the shell tests every candidate
    selector up front and records the hits here. Detection then becomes a pure
    function of this record, and is testable without a browser.

    It carried a `word_count` until ticket 021. Nothing had read it since 005
    deleted the tier that did, and while it sat here the same page could be
    probed with two different numbers depending on the caller's `mode` -- a
    presentation choice reaching into a verdict. Leaving it off means that
    cannot be written, rather than merely not being done.
    """

    url: str
    title: str
    matched_selectors: frozenset[str] = frozenset()


class Blocker(BaseModel, frozen=True):
    """A signature matched this page, so a human is genuinely required.

    Was `KnownBlocker`, against a `NovelBlocker` that meant only "this page
    had fewer words than a number I was handed". That second kind is gone
    (ticket 005), and with one kind left the distinguishing adjective is
    noise -- as is the discriminator that let a union be told apart.
    """

    signature: Signature
    probe: PageProbe


class Extraction(BaseModel, frozen=True):
    text: str
    mode_used: ExtractMode

    @property
    def word_count(self) -> int:
        """How much the page *said*, reported for the caller's information.

        Nothing decides anything with this any more. `classify` stopped
        reading a word count in ticket 005 and `choose` went with `auto` in
        021, which leaves it a display field on `Fetched` -- and ticket 022
        with the question of what a display field should be counting.

        Link targets are stripped first: they are markup, and counting them
        would let a nav bar's worth of hrefs stand in for the text an
        extractor actually kept.
        """
        return count_words(unlinked(self.text))


class FetchRequest(BaseModel, frozen=True):
    url: str
    # Required, and deliberately: see ExtractMode.
    extract_mode: ExtractMode
    wait_until: WaitUntil = WaitUntil.DOM_CONTENT_LOADED
    settle_ms: int = Field(default=1500, ge=0)
    allow_handoff: bool = True
    reuse_tab: bool = True
    keep_tab: bool = False
    close_tabs: bool = False
    as_json: bool = False
    handoff_timeout_s: int = Field(default=300, ge=1)


class ScriptRequest(BaseModel, frozen=True):
    """One call at the passthrough door (ticket 013).

    Deliberately not a FetchRequest: a script decides its own navigation, so
    the fields about *how to arrive* -- url, wait_until, settle_ms, handoff --
    have nothing to say here. What survives is what to make of the page the
    script leaves behind.
    """

    source: str
    # None means "a blank tab", which is the one-shot case. A targetId
    # continues a sequence, or picks up the tab a human just navigated.
    tab: str | None = None
    extract_mode: ExtractMode
    # A sequence that pages a listing should not pay a full read per step.
    read_page: bool = True
    timeout_s: int = Field(default=60, ge=1)
    as_json: bool = False


class LaunchPlan(BaseModel, frozen=True):
    """How a window backend wants Chrome started."""

    argv: tuple[str, ...]
    env: dict[str, str] = Field(default_factory=dict)


class Registry(BaseModel):
    """On-disk shape of signatures.json."""

    learned: list[Signature] = Field(default_factory=list)
