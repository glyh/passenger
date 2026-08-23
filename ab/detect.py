"""Functional core: deciding whether a page is blocked.

Pure. No browser, no filesystem, no clock. Everything it needs was already
measured into a PageProbe by the shell, which makes every rule here testable
without launching Chrome.
"""
import re
from typing import assert_never
from urllib.parse import urlparse

from .models import Blocker, PageProbe, Signature, SignatureKind

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


def classify(probe: PageProbe,
             signatures: tuple[Signature, ...]) -> Blocker | None:
    """A signature matched, or nothing did. None means the page is real content.

    There used to be a second tier: a page whose word count fell below
    `min_words` was reported as an unrecognised blocker. It was removed in
    ticket 005 because it was a verdict with no privileged information behind
    it. Its entire evidence was a number the caller already had, on
    `Fetched.char_count` -- and worse, that number came from whichever
    extraction the caller's `mode` happened to produce, so the same page came
    back as content or as blocked depending on a presentation choice.

    A signature match is a positive claim this tool can defend, made from
    things the caller cannot see. A short page is the caller's to judge.
    """
    for signature in signatures:
        if matches(signature, probe):
            return Blocker(signature=signature, probe=probe)
    return None
