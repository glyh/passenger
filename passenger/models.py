"""Domain models.

Every shape that crosses a boundary -- what we
measured about a page, what the CLI asked for -- is parsed into one of these
once, at the edge. Nothing downstream sees a raw dict.
"""
from enum import Enum

from pydantic import BaseModel, Field, model_validator


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

    `pending_review`, `seen_at` and `evidence` were carried for signatures the
    tool proposed to itself from pages it found thin. Ticket 005 deleted what
    wrote them and ticket 019 deleted the store that held them: every value of
    this type is now a builtin, written by hand and true of a vendor rather
    than of a site.
    """

    name: str
    kind: SignatureKind = SignatureKind.CHALLENGE
    title_re: str | None = None
    url_re: str | None = None
    selector: str | None = None

    @model_validator(mode="after")
    def _needs_a_condition(self) -> "Signature":
        if self.title_re is None and self.url_re is None and self.selector is None:
            raise ValueError(f"signature {self.name!r} has no condition")
        return self


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
    def char_count(self) -> int:
        """How big this is, for a caller sizing it against a context budget.

        It was a word count until ticket 022, segmented by ICU so that Chinese
        and Thai did not read as one word each (ticket 008). Both things that
        *decided* with the number are gone -- `classify`'s word tier in 005,
        `choose` with `auto` in 021 -- and a dictionary segmenter, this
        project's only native dependency, is not worth carrying for a number
        nobody rules on. `len(text.split())` was the one forbidden
        replacement: that is 008's bug restored, and silent now that no
        behaviour would visibly break.

        Characters are script-independent and need nothing, and they track
        tokens more closely than words do across scripts, which is the only
        question the caller actually has.

        Link targets are counted, unlike before: they are in the markdown the
        caller receives and cost it context like everything else. `unlinked`
        existed to keep a nav bar's hrefs from standing in for content when
        `choose` was comparing two extractions; nothing compares now, and
        measuring what the caller was not handed would be the lie.
        """
        return len(self.text)


class Pictures(BaseModel, frozen=True):
    """What the page renders that is not text (ticket 017).

    Geometry rather than a count, because a bare count is noise on every page
    ever made. Measured across twelve pages, the largest visible picture as a
    share of the viewport separates a three-photo note (0.38) from a listing
    of thirty thumbnails (0.06), while both the count and the summed area call
    the listing the more picture-borne of the two -- it has thirty boxes and
    1.72 viewports of them, against three and 1.16.

    `src` is how to reach that picture, not necessarily a URL: two of the five
    tags measured -- inline `svg` and `canvas` -- have no URL to give, so it
    falls back to a CSS selector, which `page.locator(sel).screenshot()` takes
    (ticket 014). A `data:` placeholder parked by a lazy loader does the same.
    """

    # The largest visible picture's area, over the viewport's. Above 1.0 for
    # an element rendered larger than the window, which is ordinary on a
    # marketing page: apple.com's hero measures 1.92.
    largest: float = Field(ge=0.0)
    # How many clear `pictures.BIG_ENOUGH` of the viewport.
    count: int = Field(ge=0)
    src: str = ""


class FetchRequest(BaseModel, frozen=True):
    url: str
    # Which lane opens and owns the tab (ticket 040). Required, and not
    # defaulted: a caller that is isolated by accident cannot tell which lane
    # it is in, and an implicit lane keyed by process was rejected for exactly
    # that -- it isolates without the caller ever asking.
    lane: str
    # Required, and deliberately: see ExtractMode.
    extract_mode: ExtractMode
    wait_until: WaitUntil = WaitUntil.DOM_CONTENT_LOADED
    settle_ms: int = Field(default=1500, ge=0)
    allow_handoff: bool = True
    reuse_tab: bool = True
    keep_tab: bool = False
    # Close this lane's other tabs afterwards. It used to close every tab in
    # the browser; under lanes it can only reach its own.
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
    lane: str
    # None means "a blank tab", which is the one-shot case. A targetId
    # continues a sequence, or picks up the tab a human just navigated. It
    # must be a tab this lane owns; another lane's is refused as absent.
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
