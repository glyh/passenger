"""Word counting across scripts.

The numbers asserted here are the ones ticket 008 measured on live
xiaohongshu pages, which is why the fixtures are sized to match: a note body
of about 1,800 Chinese characters, and a search listing against the short
ICP footer that `article` returns for the same page.
"""
from ab.text import count_words, unlinked

# A note body of the size ticket 008 measured. Chinese runs about 1.5-2
# characters per word, so ~1,800 characters should land near 1,000.
NOTE_BODY = "珠海长隆海洋王国真的值得去一趟，我们一家三口玩了两天。" * 70

# What `article` returns for the search page: the ICP footer, nothing else.
ICP_FOOTER = "小红书 京ICP备13005502号 京公网安备11010102003178号 营业执照"

# What `dom` returns for the same page: forty result cards run together.
SEARCH_LISTING = "珠海长隆海洋王国保姆级亲子游玩攻略Grace06-231933" * 40


def test_ascii_is_unchanged():
    """The fix must not move the number for text that always worked."""
    assert count_words("hello world foo") == 3


def test_empty_and_whitespace_are_zero():
    assert count_words("") == 0
    assert count_words("   \n\n\t ") == 0


def test_chinese_is_not_counted_as_one_word():
    """`len(text.split())` returned 1 here; that is the whole bug."""
    assert len("".join(NOTE_BODY.split())) > 1500
    assert count_words(NOTE_BODY) > 500


def test_a_rendered_page_measures_as_more_than_a_handful():
    """80 was the old blocked-below threshold, gone with the word-count tier
    (ticket 005). It stays here as a yardstick: both of these are live,
    readable pages that the old ruler put under it -- the note body measured
    172, the listing 66.
    """
    assert count_words(NOTE_BODY) >= 80
    assert count_words(SEARCH_LISTING) >= 80


def test_thai_is_segmented():
    """Thai has no spaces either, and no regex can split it -- ICU's
    dictionary can. The Royal Gazette case in ticket 004 is this script.
    """
    thai = "ราชกิจจานุเบกษาเป็นหนังสือพิมพ์ของรัฐ"
    assert " " not in thai
    assert count_words(thai) > 3


def test_japanese_is_segmented():
    assert count_words("ひらがなとカタカナの混ざった日本語の文章です") > 3


def test_mixed_scripts_add_up():
    """Latin and Han in one string must both be counted, not one or other."""
    assert count_words("hello 中文测试 world") > count_words("hello world")


def test_link_targets_do_not_count_as_content():
    """Ticket 007's guard.

    Both extractors emit `[label](url)` now, and a URL segments into a dozen
    or more "words". On the xiaohongshu search page the DOM text carries 70
    links against the footer's 22, which was enough on its own to drag the
    yield ratio under the floor -- `auto` would have started picking `dom`
    because of link density rather than because it kept more content.
    """
    plain = "The docs say so"
    linked = "The [docs](https://docs.python.org/3/library/asyncio-task.html) say so"
    assert count_words(unlinked(linked)) == count_words(plain)
    assert count_words(linked) > count_words(plain) + 5


def test_unlinked_keeps_bare_urls_and_plain_text():
    """Only the target half of a markdown link goes. A URL written out as
    prose is something the page actually said.
    """
    assert unlinked("see https://example.com/x now") == "see https://example.com/x now"
    assert unlinked("[a](mailto:x@y.z)") == "[a](mailto:x@y.z)"
