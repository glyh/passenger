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
    assert classify(_probe(SEARCH_LISTING), BUILTIN, min_words=80) is None


def test_a_genuinely_empty_page_is_still_blocked():
    """The threshold must keep working; the unit changed, not the intent."""
    assert classify(_probe(""), BUILTIN, min_words=80) is not None


def test_a_known_signature_still_matches():
    probe = PageProbe(url="https://example.com/", title="Just a moment...",
                      word_count=3)
    blocker = classify(probe, BUILTIN, min_words=80)
    assert blocker is not None and blocker.type == "known"
