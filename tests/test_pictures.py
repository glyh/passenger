"""The picture measurement, run against fixture documents in a real browser.

Like the walker, this is JavaScript evaluated in the page and cannot be
reached from Python -- and unlike most of it, what is under test *is* layout,
so nothing short of a browser laying the document out can exercise it at all.
The pages are `set_content` fixtures carrying their own inline CSS, because
`set_content` loads no external stylesheet and every rule here depends on one.

Each test names a failure that happened while ticket 017 was measured against
live pages. The live numbers themselves stay in
`docs/wayfinder/assets/017-pictures-findings.md` as an acceptance run, not as
a test: they move when a front page changes its lead photo.

The viewport is pinned per page. Every number this module produces is a share
of the window, so a fixture measured in a different-sized window measures
differently -- which is a property of the metric, not a flaw in it, and is the
one thing a test must hold still.
"""
import shutil

import pytest

from ab.config import CHROME_BIN
from ab.pictures import BIG_ENOUGH, measure

VIEWPORT = {"width": 1000, "height": 1000}


@pytest.fixture(scope="module")
def browser():
    playwright = pytest.importorskip("patchright.sync_api").sync_playwright
    with playwright() as driver:
        binary = shutil.which(CHROME_BIN)
        try:
            # --no-sandbox: the nix check runs as a build user with no user
            # namespace, where chromium's own sandbox cannot start.
            started = driver.chromium.launch(headless=True, args=["--no-sandbox"],
                                             **({"executable_path": binary} if binary else {}))
        except Exception as unavailable:  # pragma: no cover - environment
            pytest.skip(f"no browser to measure with: {unavailable}")
        yield started
        started.close()


@pytest.fixture
def page(browser):
    """A page in a window of known size, since every number here is a ratio."""
    context = browser.new_context(viewport=VIEWPORT)
    opened = context.new_page()
    yield opened
    context.close()


def box(w: int, h: int, tag: str = "div") -> str:
    """A picture of an exact rendered size, with no network fetch involved.

    Real `<img>` fixtures were tried first and are unusable here: an image
    whose bytes have not arrived has a zero-height box, so the fixture would
    measure the loader rather than the rule. `width`/`height` attributes plus
    a data URI pin the geometry without a request -- which is also the shape
    ticket 017 hit on the live web, where a cold fetch of xkcd measured its
    comic at 0.03 and a warm one at 0.27.
    """
    pixel = ("data:image/gif;base64,"
             "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")
    return (f'<{tag} width="{w}" height="{h}" src="{pixel}" '
            f'style="width:{w}px;height:{h}px;display:block">'
            + (f"</{tag}>" if tag != "img" else ""))


def test_the_largest_picture_is_measured_against_the_window(page):
    """The ratio is area over viewport area, and nothing else."""
    page.set_content("<body>" + box(500, 500, "img") + "</body>")
    seen = measure(page)
    # 500x500 of a 1000x1000 window.
    assert seen.largest == 0.25
    assert seen.count == 1


def test_a_thumbnail_grid_is_not_a_photo_essay(page):
    """The finding the whole metric rests on (ticket 017).

    A xiaohongshu explore listing renders 30 thumbnails at 0.06 of the window
    each -- 1.72 windows of picture in total, *more* than the 1.16 of a
    three-photo note, and thirty times the count. Every metric measured except
    this one called the listing the more picture-borne of the two.
    """
    grid = "".join(box(200, 250, "img") for _ in range(30))
    page.set_content(f"<body>{grid}</body>")
    seen = measure(page)
    assert seen.largest == 0.05
    # Nothing clears the bar, though there are thirty of them.
    assert seen.count == 0

    page.set_content("<body>" + box(700, 900, "img") * 3 + "</body>")
    note = measure(page)
    assert note.largest > seen.largest
    assert note.count == 3


def test_furniture_does_not_outweigh_the_picture(page):
    """A banner is wide, a photograph is large, and area tells them apart."""
    page.set_content("<body>" + box(1000, 90, "img")     # a leaderboard ad
                     + box(600, 600, "img") + "</body>")  # the photograph
    assert measure(page).largest == 0.36


def test_an_svg_or_a_canvas_counts_as_a_picture(page):
    """Two of the five tags have no URL at all.

    An ourworldindata grapher renders its chart as an inline `<svg>` at 0.21
    of the window, and stripe's blog as a `<canvas>` at 0.63. Both are content
    that is not text; measuring only `<img>` read them as 0.003 and 0.16.
    """
    page.set_content('<body><svg width="800" height="500" '
                     'style="width:800px;height:500px"></svg></body>')
    assert measure(page).largest == 0.4


def test_an_iframe_counts_because_its_content_is_not_in_the_markdown(page):
    """APOD, the Astronomy Picture of the Day, measured 0.00 without this.

    Its picture that day was a Vimeo `<iframe>`, 960x540. `walker.js` lists
    IFRAME in its OPAQUE set, so an iframe's content is not in the text either
    -- which makes it exactly a payload that is not text.
    """
    page.set_content('<body><iframe src="about:blank" width="800" height="500" '
                     'style="width:800px;height:500px;border:0"></iframe></body>')
    assert measure(page).largest == 0.4


def test_a_hidden_picture_is_not_a_picture(page):
    """Same visibility rule as the text walk, ticket 035's included.

    `visibility: hidden` counts as hidden here exactly as it does there, so
    the two measurements cannot disagree about what is on the page.
    """
    page.set_content('<body><div style="visibility:hidden">'
                     + box(900, 900, "img") + "</div>"
                     + box(300, 300, "img") + "</body>")
    assert measure(page).largest == 0.09


def test_a_picture_below_the_fold_still_counts(page):
    """The rule this ticket nearly got wrong.

    Requiring a box to be on screen and topmost measures *above the fold*
    rather than *rendered*, and `fetch` never scrolls: measured live, that
    filter took apple.com from 30 large pictures to 1 and moonofalabama's one
    photograph to 0. Content vanishing is a lie (ticket 035).
    """
    page.set_content('<body><div style="height:4000px">scroll past me</div>'
                     + box(800, 800, "img") + "</body>")
    seen = measure(page)
    assert seen.largest == 0.64
    assert seen.count == 1


def test_a_lazy_loader_placeholder_is_not_handed_back_as_a_url(page):
    """apple.com's 2359x1443 hero reported its src as a 1x1 base64 gif.

    True, and useless to fetch. The element is still there, so `src` falls
    back to a selector that `page.locator(...)` resolves -- which the fixtures
    above exercise incidentally, since every one of them is a data URI.
    """
    page.set_content("<body><div><span>" + box(800, 800, "img")
                     + "</span></div></body>")
    seen = measure(page)
    assert not seen.src.startswith("data:")
    assert page.locator(seen.src).count() == 1


def test_a_real_url_is_preferred_to_a_selector(page):
    """The common case, and the more useful of the two forms."""
    page.set_content('<body><img src="https://ex.test/photo.jpg" width="800" '
                     'height="800" style="width:800px;height:800px"></body>')
    assert measure(page).src == "https://ex.test/photo.jpg"


def test_a_page_that_cannot_answer_reports_no_pictures(page):
    """Ticket 012's wedged renderer. A measurement is not worth a whole fetch.

    Unlike `dom_text`'s fallback there is nothing here that could mask a bug:
    an exception reports zero, and zero is also what a page of pure text
    reports, so no assertion elsewhere can pass on the strength of this path.
    """
    def wedged(*_args, **_kwargs):
        raise RuntimeError("Execution context was destroyed")

    page.set_content("<body>" + box(900, 900, "img") + "</body>")
    page.evaluate = wedged
    seen = measure(page)
    assert seen.largest == 0.0
    assert seen.count == 0
    assert seen.src == ""


def test_the_threshold_belongs_to_python(page):
    """`BIG_ENOUGH` is passed in, as `_STRIP` and `_ROOTS` are for the walker.

    A reader looks for the constant on the Python side, and a page sitting
    just under it must not be counted -- 10% was chosen because 5% made the
    count contradict the ratio on a thumbnail listing.
    """
    assert BIG_ENOUGH == 0.10
    under = int((BIG_ENOUGH * 1000 * 1000) ** 0.5) - 10
    page.set_content("<body>" + box(under, under, "img") + "</body>")
    assert measure(page).count == 0
    page.set_content("<body>" + box(under + 20, under + 20, "img") + "</body>")
    assert measure(page).count == 1
