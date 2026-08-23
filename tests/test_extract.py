"""The pure half of extraction: the tidying ticket 025's markup work depends
on.

It also held the `auto` decision, which ticket 021 deleted -- `choose` is gone,
so the four tests that pinned its floors went with it. What they were defending
was a comparison that could not see the page's type (ticket 011); the caller
now says which extractor it wants, and there is no decision here left to test.

`tidy` is pure by design, so none of this needs a browser. The walker itself is
JavaScript over a live DOM and is covered separately, in `test_walker.py`,
which does start one.
"""
from ab.extract import tidy


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
