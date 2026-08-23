"""The DOM walker, run against fixture documents in a real browser.

The walker is JavaScript over a live DOM, so unlike the rest of `extract` it
cannot be reached from Python. Ticket 025 measured it against live pages
instead, and ticket 028 is the bug that hid in the gap: a page whose furniture
matches `article` thirty times over, where the walker started from a promo
card and returned it as the document.

Nothing here fetches anything. The failure is entirely in which element the
walk begins at, so the pages are `set_content` fixtures -- the smallest thing
that reproduces a shape.

This is the first test in the suite that starts a browser. Ticket 001 ruled
that the suite starts no Chrome, and meant the nested cage/wayvnc stack; a
headless browser handed a string of HTML shares none of that cost. The flake
pins one for `nix flake check` so this does not quietly skip in the one
command that gates the repo.
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
    opened = browser.new_page()
    yield opened
    opened.close()


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
