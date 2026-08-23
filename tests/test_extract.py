"""The pure half of extraction: the `auto` decision ticket 008 caught returning
the empty extraction, and the tidying ticket 025's markup work depends on.

`choose` and `tidy` are pure by design, so none of this needs a browser. The
walker itself is JavaScript and is not reachable from here; it was measured
against live pages instead.
"""
from ab.extract import choose, tidy
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


def test_a_code_block_keeps_its_indentation():
    """The failure ticket 025's markup work would have shipped with.

    The walker has always kept `PRE` whitespace and `tidy` has always stripped
    it back off line by line, which did not matter while a code block was
    indistinguishable from prose. Once `dom` fences them, a Python sample whose
    body has been flattened against its `def` is not the sample.
    """
    raw = "prose  here\n```\ndef f():\n    print(x)\n\n    return x\n```\nmore  prose"
    out = tidy(raw)
    assert "    print(x)" in out
    assert "\n\n    return x" in out
    assert "prose here" in out and "more prose" in out


def test_an_unterminated_fence_does_not_swallow_the_page():
    """A page that opens a fence and never closes it still gets tidied for the
    part before it, rather than the whole rest of the document passing through
    raw. Only exact ``` lines toggle, so prose mentioning a fence inline is
    unaffected.
    """
    out = tidy("a  b\n```\nkept  as is\n")
    assert "a b" in out
    assert "kept  as is" in out
    assert tidy("she wrote ``` in  a sentence") == "she wrote ``` in a sentence"
