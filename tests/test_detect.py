"""Liveness classification. Pure: a fixture PageProbe, no browser."""
from ab.detect import classify
from ab.models import PageProbe
from ab.registry import BUILTIN
from ab.text import count_words
from tests.test_text import SEARCH_LISTING


def _probe(text: str, title: str = "珠海长隆海洋王国 - 小红书搜索",
           url: str = "https://www.xiaohongshu.com/search_result?keyword=x"):
    return PageProbe(url=url, title=title, word_count=count_words(text))


def test_a_rendered_cjk_listing_is_not_blocked():
    """Ticket 008: this page counted 66 words, under the default 80, so a
    fully rendered listing with nothing in its way was called blocked and a
    signature was proposed that would have blocklisted one search phrase.
    """
    assert classify(_probe(SEARCH_LISTING), BUILTIN) is None


def test_an_empty_page_is_not_blocked_on_its_emptiness():
    """Ticket 005: a word count is no longer a verdict.

    This used to assert the opposite. An empty page is now simply an empty
    page -- the tool reports `word_count` and the caller judges, because a
    short page was the one thing `classify` claimed to know that the caller
    could already see for itself.
    """
    assert classify(_probe(""), BUILTIN) is None


def test_a_known_signature_still_matches():
    probe = PageProbe(url="https://example.com/", title="Just a moment...",
                      word_count=3)
    blocker = classify(probe, BUILTIN)
    assert blocker is not None
    assert blocker.signature.name == "cloudflare-interstitial"


def test_a_short_page_with_no_signature_is_content():
    """The pairing that motivated 005 and 010: example.com is thirty-odd
    words, which used to be enough to seize the screen for five minutes.
    """
    probe = PageProbe(url="https://example.com/", title="Example Domain",
                      word_count=30)
    assert classify(probe, BUILTIN) is None


def test_the_mode_can_no_longer_change_the_verdict():
    """Ticket 005's own defect: the same page, twice, differing only in the
    extraction handed to `probe` -- 2,109 words through dom and near-zero
    through article. Nothing about a signature match reads that number.
    """
    live = PageProbe(url="https://ratchakitcha.soc.go.th/search-result/",
                     title="ราชกิจจานุเบกษา", word_count=2109)
    gutted = live.model_copy(update={"word_count": 1})
    assert classify(live, BUILTIN) == classify(gutted, BUILTIN) is None
