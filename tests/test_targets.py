"""Parsing Chrome's target list. Pure: a recorded payload, no browser."""
from passenger.models import Wedge
from passenger.targets import parse, verdict

# Recorded from the live endpoint while a tab sat stuck mid-navigation
# (ticket 012). Note the stuck tab: its title is still the document it had
# before the navigation started, which is why the title cannot be used to
# tell a stuck tab from a healthy one -- only asking its renderer can.
LISTING = """[
  {"description": "", "devtoolsFrontendUrl": "/devtools/inspector.html?ws=x",
   "id": "35220A8B", "title": "about:blank", "type": "page",
   "url": "http://10.255.255.1:81/hang",
   "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/35220A8B"},
  {"description": "", "id": "C3E56F6E", "title": "Example Domain",
   "type": "page", "url": "https://example.com/",
   "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/C3E56F6E"},
  {"description": "", "id": "867A5141", "title": "Omnibox Popup",
   "type": "browser_ui", "url": "chrome://omnibox-popup.top-chrome/",
   "webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/page/867A5141"}
]"""


def test_every_target_is_parsed_with_its_socket():
    targets = parse(LISTING)
    assert len(targets) == 3
    assert targets[0].websocket_url.endswith("/35220A8B")


def test_chrome_s_own_ui_is_not_a_page():
    """Chrome lists its omnibox popup as a target. Stopping *its* navigation
    would be meaningless, and it is not a tab anyone opened."""
    assert [t.id for t in parse(LISTING) if t.is_page] == ["35220A8B", "C3E56F6E"]


def test_a_stuck_tab_looks_ordinary_from_the_outside():
    """Ticket 012: the stuck tab still reports the title of the document it
    had before the navigation began, and a healthy tab with no <title> reports
    its URL. Nothing in this payload separates them, which is why unstick()
    asks the renderer instead of reading fields."""
    stuck, healthy = parse(LISTING)[:2]
    assert stuck.title and healthy.title


# --- What one `Page.getFrameTree` answer says about a tab (ticket 042).
#
# Recorded from the live endpoint against a socket that accepts and then
# answers nothing. Two tabs pointed at it, and they answer *differently*: the
# one that already had a document goes silent, the one created at the URL
# answers at once and says it has no document.

SILENT = None  # the renderer never answered at all

UNCOMMITTED = {"id": 1, "result": {"frameTree": {"frame": {
    "id": "9D5703E5", "loaderId": "A1", "url": "",
    "securityOrigin": "://", "mimeType": ""}}}}

HEALTHY = {"id": 1, "result": {"frameTree": {"frame": {
    "id": "9D5703E5", "loaderId": "A1", "url": "https://example.com/",
    "securityOrigin": "https://example.com", "mimeType": "text/html"}}}}

BLANK = {"id": 1, "result": {"frameTree": {"frame": {
    "id": "9D5703E5", "loaderId": "A1", "url": "about:blank",
    "securityOrigin": "://", "mimeType": "text/html"}}}}

REFUSED = {"id": 1, "error": {"code": -32000, "message": "Not attached"}}


def test_a_renderer_that_never_answers_is_the_wedge_012_knew():
    assert verdict(SILENT) is Wedge.SILENT


def test_a_tab_with_no_document_is_wedged_even_though_it_answered():
    """Ticket 042: the tab reads as healthy by every other measure -- it
    answers in under 10ms -- and it hangs the attach as hard as a silent one.
    The empty frame URL is the whole difference."""
    assert verdict(UNCOMMITTED) is Wedge.UNCOMMITTED


def test_about_blank_is_a_document_and_not_a_wedge():
    """The distinction the empty string turns on: `about:blank` is a page that
    committed, and a tab sitting on one is the most ordinary thing here."""
    assert verdict(BLANK) is None


def test_a_loaded_page_is_left_alone():
    assert verdict(HEALTHY) is None


def test_an_error_reply_is_not_read_as_a_wedge():
    """It is still an answer, so the renderer is alive; it is just not one a
    frame can be read out of. The remedies stop navigations, so a reply nobody
    planned for is a bad reason to fire one."""
    assert verdict(REFUSED) is None
