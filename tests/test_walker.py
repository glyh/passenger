"""The DOM walker, run against fixture documents in a real browser.

The walker is JavaScript evaluated in the page, so unlike the rest of
`extract` it cannot be reached from Python. Ticket 025 measured it against
live pages instead, and ticket 028 is the bug that hid in the gap: a page
whose furniture matches `article` thirty times over, where the walk started
from a promo card and returned it as the document.

Nothing here fetches anything. The pages are `set_content` fixtures -- the
smallest thing that reproduces a shape -- and synthetic rather than captured,
because `set_content` loads no external CSS: a saved real page arrives without
its stylesheet, which is fatal for anything testing what is visible. Where the
behaviour under test depends on CSS, the fixture carries it inline. Ticket
025's five real pages stay an acceptance run recorded in `assets/`, not a test.

This is the first test in the suite that starts a browser. Ticket 001 ruled
that the suite starts no Chrome, and meant the nested cage/wayvnc stack; a
headless browser handed a string of HTML shares none of that cost. The flake
pins one for `nix flake check` so this does not quietly skip in the one
command that gates the repo.

Every test here enters through `dom_text`, which is the only call site that
exists in production. There is deliberately no seam into the JavaScript --
ticket 001 refused one for `_alive` on the same grounds, and the argument is
stronger here, since `label()`'s whole behaviour is `innerText`, `getAttribute`
and a descendant query. A seam would let a test pass against a mock and fail
against Chrome, which is the failure a seam exists to prevent, inverted.
"""
import shutil

import pytest

from ab.config import CHROME_BIN
from ab.extract import dom_text

# Three cards of the size americanthinker's are (79-203 characters), so the
# first one clears the 40-character guard exactly as the real page's did.
_CARD = ("<article><h3><a href='https://ex.test/a{i}'>Teaser headline number "
         "{i}</a></h3><p>A promo card advertising some other piece entirely, "
         "long enough to look like content.</p></article>")
_BODY = ("<div class='main_information'><p>" + "The real piece. " * 60
         + "</p></div>")
DECOY_PAGE = ("<body><div class='grid'>"
              + "".join(_CARD.format(i=i) for i in range(30))
              + _BODY + "</div></body>")

# Every fixture below needs its root to clear `dom`'s 40-character emptiness
# guard before anything else can be asserted about the walk.
FILLER = "<p>Enough prose here to clear the emptiness guard comfortably.</p>"


@pytest.fixture(scope="module")
def browser():
    """A headless browser, preferring the one the project already depends on.

    `patchright` falls back to its own bundled chromium when the configured
    binary is not installed, which is what makes this runnable on a developer
    machine that has neither.
    """
    playwright = pytest.importorskip("patchright.sync_api").sync_playwright
    with playwright() as driver:
        binary = shutil.which(CHROME_BIN)
        try:
            # --no-sandbox: the nix check runs as a build user with no user
            # namespace, where chromium's own sandbox cannot start.
            started = driver.chromium.launch(headless=True, args=["--no-sandbox"],
                                             **({"executable_path": binary} if binary else {}))
        except Exception as unavailable:  # pragma: no cover - environment
            pytest.skip(f"no browser to walk with: {unavailable}")
        yield started
        started.close()


@pytest.fixture
def page(browser):
    """A page whose `inner_text` is poisoned, so no test can pass on a fallback.

    `dom_text` catches everything the evaluate can raise and degrades to
    `page.inner_text("body")`, which for most fixtures still contains every
    string a test looks for. Measured before this fixture existed: replacing
    the walker's JavaScript with a syntax error left two of the three tests
    then in this file passing, including the one ticket 028 was written for.
    A test that cannot tell a working walker from a dead one is not a test.

    The fallback itself is deliberate and stays -- ticket 012's wedged
    renderer really does stop answering. What it must not do is stand in for
    our own bugs, so here it is unreachable and a broken walker fails loudly.
    """
    opened = browser.new_page()

    def poisoned(*_args, **_kwargs):
        raise AssertionError(
            "dom_text fell back to inner_text: the walker did not run")

    opened.inner_text = poisoned
    yield opened
    opened.close()


@pytest.fixture
def served(page):
    """A page served from a real https URL, for the one rule that needs one.

    `set_content` leaves the document at `about:blank`, where a relative href
    resolves to nothing `^https?:` matches -- so link *resolution*, which is
    half of what ticket 007 settled, is invisible under it. Fulfilling the
    route locally keeps the suite offline while giving the document an origin
    and a directory to resolve against.
    """
    def _serve(html: str, url: str = "https://ex.test/dir/page"):
        page.route("**/*", lambda route: route.fulfill(
            body=html, content_type="text/html"))
        page.goto(url)
        return page
    return _serve


def test_many_articles_are_a_listing_not_a_document(page):
    """Ticket 028, on the shape that caused it.

    `querySelector('article')` returned the first of thirty promo cards, its
    164 characters cleared the guard, and americanthinker's 5,769-character
    piece was never reached -- `dom` returned the card advertising the very
    article that was asked for.
    """
    page.set_content(DECOY_PAGE)
    text = dom_text(page)
    assert "The real piece." in text
    # Not merely reached: the whole body, not a fragment of it.
    assert text.count("The real piece.") == 60


def test_a_single_article_is_still_the_root(page):
    """The other direction. One `<article>` is what the tag is for, and the
    fix must not cost the pages where the selector was right."""
    page.set_content("<body><nav>Home About Contact</nav>"
                     "<article><p>" + "Body sentence. " * 20 + "</p></article>"
                     "<div>Sidebar furniture that is not part of the piece.</div></body>")
    text = dom_text(page)
    assert "Body sentence." in text
    assert "Sidebar furniture" not in text


def test_an_empty_container_is_not_the_root(page):
    """The 40-character guard, which survives the fix with a narrower job: it
    is not a quality bar but an emptiness check, for a shell whose content
    lives somewhere else."""
    page.set_content("<body><main></main><p>" + "Content elsewhere. " * 10
                     + "</p></body>")
    assert "Content elsewhere." in dom_text(page)


def test_adjacent_blocks_do_not_run_together(page):
    """Ticket 007's real bug, which the link work uncovered.

    The walk used to run over a detached clone, where `innerText` is
    `textContent` -- so `dom` never had block boundaries at all and returned
    one unbroken run of prose. Every paragraph in a document ran into the
    next.
    """
    page.set_content("<body><main>"
                     "<p>First paragraph of the piece.</p>"
                     "<p>Second paragraph of the piece.</p>"
                     "</main></body>")
    text = dom_text(page)
    assert "piece.Second" not in text
    assert "First paragraph of the piece." in text.splitlines()
    assert "Second paragraph of the piece." in text.splitlines()


def test_a_relative_href_is_resolved_against_the_document(served):
    """Ticket 007: a listing read through `dom` had no link targets.

    Resolution is against the document, so a relative href becomes reachable
    rather than a fragment nobody can follow.
    """
    text = dom_text(served(
        "<body><main>" + FILLER
        + "<p><a href='../other/thing'>Somewhere else</a></p>"
        "</main></body>"))
    assert "[Somewhere else](https://ex.test/other/thing)" in text


def test_a_signed_query_string_survives_byte_for_byte(page):
    """Ticket 007 forbade normalising, and named why: a signed query string
    *is* the URL. Percent-encoding that a normaliser would helpfully decode
    is the case that breaks a signature."""
    signed = "https://ex.test/o?sig=aB%2FcD%3D%3D&amp;e=1"
    page.set_content("<body><main>" + FILLER
                     + f"<p><a href='{signed}'>Signed target</a></p></main></body>")
    assert "[Signed target](https://ex.test/o?sig=aB%2FcD%3D%3D&e=1)" in dom_text(page)


def test_a_fragment_link_is_not_emitted_as_a_link(page):
    """`node.href` resolves `#section` into a link back to this same page,
    which is cost without a target. The label survives as prose; the URL does
    not survive at all."""
    page.set_content("<body><main>" + FILLER
                     + "<p><a href='#section'>Jump to section</a></p></main></body>")
    text = dom_text(page)
    assert "Jump to section" in text
    assert "#section" not in text
    assert "](" not in text


def test_an_unlabelled_anchor_goes_only_when_something_else_points_there(page):
    """Ticket 007's histogram rule, both directions.

    A URL with no label is cost without information -- unless nothing else on
    the page points there, in which case dropping it loses the target
    outright. That kept the one search result whose card is a bare cover
    image, and dropped the other nineteen cover anchors that merely repeat
    their card's title link.
    """
    page.set_content(
        "<body><main>" + FILLER
        + "<p><a href='https://ex.test/note'><img src='cover.png'></a>"
        "<a href='https://ex.test/note'>The note title</a></p>"
        "<p><a href='https://ex.test/lonely'><img src='only.png'></a></p>"
        "</main></body>")
    text = dom_text(page)
    # Twice-pointed-at: the labelled anchor stands for both.
    assert text.count("https://ex.test/note") == 1
    assert "[The note title](https://ex.test/note)" in text
    # Once-pointed-at: kept unlabelled rather than lost.
    assert "[](https://ex.test/lonely)" in text


def test_an_anchor_with_no_text_takes_its_label_from_an_attribute(page):
    """`extract.py`'s `label()` reads `innerText` first and reaches the
    attributes only when that is empty -- an icon link carries its label in
    `aria-label`, an image link in `alt`. Ticket 030's own inventory of what
    the walker does omitted this path entirely, which is how easy it is to
    forget."""
    page.set_content(
        "<body><main>" + FILLER
        + "<p><a href='https://ex.test/a' aria-label='Open the menu'></a>"
        "<a href='https://ex.test/b' title='Share this'></a>"
        "<a href='https://ex.test/c'><img src='p.png' alt='A photograph'></a>"
        "</p></main></body>")
    text = dom_text(page)
    assert "[Open the menu](https://ex.test/a)" in text
    assert "[Share this](https://ex.test/b)" in text
    assert "[A photograph](https://ex.test/c)" in text


def test_a_list_marker_waits_for_the_text_it_marks(page):
    """Ticket 025's orphaned marker.

    `- ` written the moment an `<li>` opens lands alone on its line as soon as
    the item's first child is a block -- and on documentation most of them
    are, so a whole list came out as bare dashes standing above their items.
    """
    page.set_content("<body><main>" + FILLER
                     + "<ul><li><div>First item body</div></li>"
                     "<li><div>Second item body</div></li></ul></main></body>")
    lines = dom_text(page).splitlines()
    assert "- First item body" in lines
    assert "- Second item body" in lines
    assert "-" not in [line.strip() for line in lines]


def test_a_marker_for_an_empty_block_does_not_label_the_next_one(page):
    """The other half of the deferred marker, same commit.

    An unflushed marker belongs to a block that turned out to hold nothing.
    Left standing it labels whatever text arrives next, which is a different
    block entirely.
    """
    page.set_content("<body><main>" + FILLER
                     + "<ul><li></li></ul>"
                     "<p>Prose that follows the list</p></main></body>")
    lines = dom_text(page).splitlines()
    assert "Prose that follows the list" in lines
    assert "- Prose that follows the list" not in lines


def test_a_code_block_is_fenced_with_its_indentation_intact(page):
    """Ticket 025 gave `dom` fences; ticket 009 found them to be the one axis
    on which an extractor visibly wins, which makes them the axis a
    documentation page is lost on. A sample whose body has been flattened
    against its `def` is not the sample."""
    page.set_content("<body><main>" + FILLER
                     + "<pre>def f(x):\n    return x + 1</pre></main></body>")
    text = dom_text(page)
    assert text.count("```") == 2
    assert "    return x + 1" in text.splitlines()


def test_display_none_and_visibility_hidden_go_but_opacity_stays(page):
    """What `checkVisibility()` filters, and the one option deliberately refused.

    Ticket 025 recorded `dom` dropping gmw's hidden WeChat share overlay where
    trafilatura swallowed it, and that difference is part of why 025 kept both
    extractors. The mechanism turned out to be narrower than its name: called
    with no arguments, `checkVisibility()` defaults `visibilityProperty`,
    `opacityProperty` and `contentVisibilityAuto` to false, so it reported only
    `display:none` and three hiding mechanisms leaked (ticket 035).

    `visibilityProperty` is now on. `opacityProperty` is not, and that is the
    measurement rather than caution: scroll-triggered reveal holds
    below-the-fold content at `opacity: 0` until a reader arrives, and this
    tool never scrolls -- apple.com fell from 13,081 characters to 3,761, real
    body text, against a gain of three lines of dialog chrome elsewhere. So
    opacity staying visible is the deliberate choice, and this pins it.
    """
    page.set_content(
        "<body><main>" + FILLER
        + "<p style='display:none'>Hidden by display</p>"
        "<p style='visibility:hidden'>Hidden by visibility</p>"
        "<p style='opacity:0'>Faded out but present</p>"
        "</main></body>")
    text = dom_text(page)
    assert "Hidden by display" not in text
    assert "Hidden by visibility" not in text
    # Deliberate. See the docstring and ticket 035; opacity is not a hiding
    # mechanism this tool can distinguish from an unfinished animation.
    assert "Faded out but present" in text
