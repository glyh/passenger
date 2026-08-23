"""Liveness classification. Pure: a fixture PageProbe, no browser.

`test_the_mode_can_no_longer_change_the_verdict` lived here and cannot be
written any more: ticket 021 took `word_count` off `PageProbe`, so the number
the extraction mode used to reach a verdict through is not in the record at
all. That guarantee is now structural rather than tested.

`classify` took the signature table as an argument until ticket 019, filled
from a registry that could add learned rules to it. There is one table now and
it is read directly, so these calls pass a probe and nothing else.
"""
from passenger.detect import classify
from passenger.models import PageProbe


def _probe(title: str = "珠海长隆海洋王国 - 小红书搜索",
           url: str = "https://www.xiaohongshu.com/search_result?keyword=x"):
    return PageProbe(url=url, title=title)


def test_a_rendered_cjk_listing_is_not_blocked():
    """Ticket 008: this page counted 66 words, under the default 80, so a
    fully rendered listing with nothing in its way was called blocked and a
    signature was proposed that would have blocklisted one search phrase.
    Nothing counts it now, and no builtin matches a search URL.
    """
    assert classify(_probe()) is None


def test_a_known_signature_still_matches():
    probe = PageProbe(url="https://example.com/", title="Just a moment...")
    blocker = classify(probe)
    assert blocker is not None
    assert blocker.signature.name == "cloudflare-interstitial"


def test_a_short_page_with_no_signature_is_content():
    """The pairing that motivated 005 and 010: example.com is thirty-odd
    words, which used to be enough to seize the screen for five minutes.
    """
    probe = PageProbe(url="https://example.com/", title="Example Domain")
    assert classify(probe) is None
