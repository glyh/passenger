"""The `auto` decision, which ticket 008 caught returning the empty extraction.

`choose` is pure by design, so none of this needs a browser.
"""
from ab.extract import choose
from ab.models import ExtractMode
from tests.test_text import ICP_FOOTER, NOTE_BODY, SEARCH_LISTING


def test_listing_picks_dom_over_a_footer():
    """The case from ticket 008.

    On a xiaohongshu search page, `article` yields the ICP footer and `dom`
    yields forty result cards. Counted with `split()` both measured in the
    sixties -- noise against noise -- so the yield floor never tripped and
    `auto` returned the footer, discarding the entire result set.
    """
    picked = choose(article=ICP_FOOTER, dom=SEARCH_LISTING)
    assert picked.mode_used is ExtractMode.DOM
    assert picked.text == SEARCH_LISTING


def test_article_wins_when_it_kept_the_content():
    """The other direction must still hold: on a note page `article` returns
    a clean body and `dom` returns the same body with the recommendation feed
    glued to the front, so article is right and must not be discarded.
    """
    picked = choose(article=NOTE_BODY, dom="推荐 发现 关注 " * 30 + NOTE_BODY)
    assert picked.mode_used is ExtractMode.ARTICLE


def test_ascii_behaviour_is_unchanged():
    """A Latin page where article legitimately wins."""
    article = " ".join(["word"] * 200)
    dom = " ".join(["word"] * 220)
    assert choose(article, dom).mode_used is ExtractMode.ARTICLE


def test_a_gutted_article_loses_to_dom():
    """The floor's original purpose, on text that always counted correctly."""
    article = "Skip to content"
    dom = " ".join(["word"] * 200)
    assert choose(article, dom).mode_used is ExtractMode.DOM
