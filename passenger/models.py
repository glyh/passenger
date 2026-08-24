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


class WaitFor(str, Enum):
    """What ends a `show_browser` wait.

    Two different facts, and the difference is the point (ticket 018). CLOSED
    is the human saying they are done, which is the one completion signal this
    tool does not have to infer. UNBLOCKED is the page saying the wall is gone,
    which is stronger -- a human can close a viewer without solving anything --
    but only reaches walls the fixed signature table can name.
    """

    CLOSED = "closed"
    UNBLOCKED = "unblocked"


class Wedge(str, Enum):
    """How a tab is holding the attach open, when it is.

    Two different failures wearing one symptom. SILENT is ticket 012's: the
    renderer has stopped answering anything, and stopping its load frees it
    with the document it already had intact. UNCOMMITTED is ticket 042's: the
    renderer answers everything instantly and holds no document at all,
    because the navigation that created it is still waiting on a server that
    has not sent headers.

    Measured, and the reason they cannot share a remedy: `Page.stopLoading` on
    an UNCOMMITTED tab is answered, clears the pending URL, and leaves the
    attach hanging exactly as before. Navigating it to about:blank frees it --
    and costs nothing, since a tab with no document has nothing to lose.
    """

    SILENT = "silent"
    UNCOMMITTED = "uncommitted"


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


class ScriptRequest(BaseModel, frozen=True):
    """One call at the passthrough door (ticket 013).

    The only door there is, since ticket 046 retired `fetch`. A script decides
    its own navigation, so nothing here says how to arrive; what is left is
    which tab, whose lane, and how long any one Playwright call may take.

    There is no `extract_mode` and no `read_page` because there is no
    extraction. The reply carries what the ending page *measures* -- a
    character count, the pictures, a vendor's wall -- and never what it means.
    """

    source: str
    lane: str
    # None means "a blank tab", which is the one-shot case. A targetId
    # continues a sequence, or picks up the tab a human just navigated. It
    # must be a tab this lane owns; another lane's is refused as absent.
    tab: str | None = None
    timeout_s: int = Field(default=60, ge=1)
    as_json: bool = False


class LaunchPlan(BaseModel, frozen=True):
    """How a window backend wants Chrome started."""

    argv: tuple[str, ...]
    env: dict[str, str] = Field(default_factory=dict)
