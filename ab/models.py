"""Domain models.

Every shape that crosses a boundary -- the signature registry on disk, what we
measured about a page, what the CLI asked for -- is parsed into one of these
once, at the edge. Nothing downstream sees a raw dict.
"""
from enum import Enum
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field, model_validator


class SignatureKind(str, Enum):
    CHALLENGE = "challenge"
    LOGIN = "login"
    UNKNOWN = "unknown"


class ExtractMode(str, Enum):
    AUTO = "auto"
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


class PageProbe(BaseModel, frozen=True):
    """What the shell measured about a loaded page.

    Selector evaluation needs the live page, so the shell tests every candidate
    selector up front and records the hits here. Detection then becomes a pure
    function of this record, and is testable without a browser.
    """

    url: str
    title: str
    word_count: int
    matched_selectors: frozenset[str] = frozenset()


class KnownBlocker(BaseModel, frozen=True):
    type: Literal["known"] = "known"
    signature: Signature
    probe: PageProbe


class NovelBlocker(BaseModel, frozen=True):
    """Nothing matched, but the page yielded too little to be real content."""

    type: Literal["novel"] = "novel"
    probe: PageProbe


Blocker = KnownBlocker | NovelBlocker


class Evidence(BaseModel, frozen=True):
    probe: PageProbe
    iframe_srcs: tuple[str, ...] = ()
    visible_text: tuple[str, ...] = ()
    screenshot: Path | None = None


class Extraction(BaseModel, frozen=True):
    text: str
    mode_used: ExtractMode

    @property
    def word_count(self) -> int:
        return len(self.text.split())


class FetchRequest(BaseModel, frozen=True):
    url: str
    extract_mode: ExtractMode = ExtractMode.AUTO
    wait_until: WaitUntil = WaitUntil.DOM_CONTENT_LOADED
    settle_ms: int = Field(default=1500, ge=0)
    min_words: int = Field(default=80, ge=0)
    allow_handoff: bool = True
    reuse_tab: bool = True
    keep_tab: bool = False
    close_tabs: bool = False
    as_json: bool = False


class LaunchPlan(BaseModel, frozen=True):
    """How a window backend wants Chrome started."""

    argv: tuple[str, ...]
    env: dict[str, str] = Field(default_factory=dict)


class Registry(BaseModel):
    """On-disk shape of signatures.json."""

    learned: list[Signature] = Field(default_factory=list)
