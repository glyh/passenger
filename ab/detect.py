"""Functional core: deciding whether a page is blocked.

Pure. No browser, no filesystem, no clock. Everything it needs was already
measured into a PageProbe by the shell, which makes every rule here testable
without launching Chrome.
"""
import re
from typing import assert_never
from urllib.parse import urlparse

from .models import (Blocker, Evidence, KnownBlocker, NovelBlocker, PageProbe,
                     Signature, SignatureKind)

BUILTIN: tuple[Signature, ...] = (
    Signature(name="cloudflare-interstitial",
              title_re=r"^(Just a moment|Attention Required|Please Wait)"),
    Signature(name="cloudflare-turnstile",
              selector="iframe[src*='challenges.cloudflare.com']"),
    Signature(name="recaptcha",
              selector="iframe[src*='recaptcha/api2/bframe'], "
                       "iframe[src*='recaptcha/enterprise/bframe']"),
    Signature(name="hcaptcha",
              selector="iframe[src*='hcaptcha.com'][src*='frame=challenge'], "
                       "iframe[src*='newassets.hcaptcha.com/captcha']"),
    Signature(name="arkose-funcaptcha",
              selector="iframe[src*='arkoselabs.com'], iframe[src*='funcaptcha.com']"),
    Signature(name="datadome",
              selector="iframe[src*='captcha-delivery.com'], #datadome-captcha"),
    Signature(name="px-human", selector="#px-captcha, [id^='px-captcha']"),
    Signature(name="login-wall", kind=SignatureKind.LOGIN,
              url_re=r"/(login|signin|sign-in|sso|auth|accounts/login)(/|\?|$)"),
)


def selectors_of(signatures: tuple[Signature, ...]) -> tuple[str, ...]:
    """Every selector the shell must test against the live page."""
    return tuple(s.selector for s in signatures if s.selector is not None)


def matches(signature: Signature, probe: PageProbe) -> bool:
    """Every condition the signature declares must hold."""
    if signature.title_re is not None:
        if re.search(signature.title_re, probe.title, re.I) is None:
            return False
    if signature.url_re is not None:
        if re.search(signature.url_re, probe.url, re.I) is None:
            return False
    if signature.selector is not None:
        if signature.selector not in probe.matched_selectors:
            return False
    return True


def classify(probe: PageProbe, signatures: tuple[Signature, ...],
             min_words: int) -> Blocker | None:
    """Tier 1 then tier 2. None means the page looks like real content."""
    for signature in signatures:
        if matches(signature, probe):
            return KnownBlocker(signature=signature, probe=probe)
    if probe.word_count < min_words:
        return NovelBlocker(probe=probe)
    return None


def blocker_name(blocker: Blocker) -> str:
    match blocker:
        case KnownBlocker(signature=signature):
            return signature.name
        case NovelBlocker():
            return "unknown-blocker"
        case _ as unreachable:
            assert_never(unreachable)


def is_novel(blocker: Blocker) -> bool:
    match blocker:
        case KnownBlocker():
            return False
        case NovelBlocker():
            return True
        case _ as unreachable:
            assert_never(unreachable)


def propose_signature(evidence: Evidence, stamp: int) -> Signature | None:
    """Derive a candidate rule from a novel blocker.

    Returns None when nothing distinctive was observable -- better no rule than
    one with no condition, which would be either inert or indiscriminate.

    Always pending_review: a rule inferred from a single page is exactly the
    kind that starts matching pages it shouldn't.
    """
    host = urlparse(evidence.probe.url).netloc
    third_party = _third_party_frame_host(evidence.iframe_srcs, host)

    common = {
        "name": f"learned-{host}-{stamp}",
        "kind": SignatureKind.UNKNOWN,
        "pending_review": True,
        "seen_at": evidence.probe.url,
        "evidence": evidence.screenshot,
    }
    if third_party is not None:
        return Signature(selector=f"iframe[src*='{third_party}']", **common)
    if evidence.probe.title.strip():
        return Signature(title_re="^" + re.escape(evidence.probe.title[:60]),
                         **common)
    return None


def _third_party_frame_host(srcs: tuple[str, ...], page_host: str) -> str | None:
    """A frame from someone else's domain is the most reliable single tell."""
    for src in srcs:
        frame_host = urlparse(src).netloc
        if frame_host and frame_host not in page_host:
            return frame_host
    return None
