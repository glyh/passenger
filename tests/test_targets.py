"""Parsing Chrome's target list. Pure: a recorded payload, no browser."""
from passenger.targets import parse

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
