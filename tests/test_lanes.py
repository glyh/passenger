"""The lane registry, without a browser.

Everything here is the table and its rules; nothing opens Chrome. What is left
untested by that boundary is named at the bottom of ticket 040 -- adoption
against a real popup, the screen refcount across two live processes, and expiry
actually closing tabs.

`conftest` points PASSENGER_STATE at a temp directory before `passenger` is
imported, so `lanes.DB_FILE` is already inside it: these tests never touch a
developer's real registry.
"""
import time

import pytest

from passenger import lanes, targets
from passenger.errors import LaneNotFound


@pytest.fixture(autouse=True)
def fresh() -> None:
    """Each test starts on an empty table, since the file is shared."""
    lanes.reset()


def test_open_lane_mints_distinct_ids() -> None:
    assert lanes.open_lane() != lanes.open_lane()


def test_reserved_lanes_exist_without_being_opened() -> None:
    assert lanes.require(lanes.CLI).ttl_s == lanes.DEFAULT_TTL_S
    # `orphan` never expires: a TTL there would collect the tabs a human
    # opened during a handoff, which is what ticket 018 exists to prevent.
    assert lanes.require(lanes.ORPHAN).ttl_s == lanes.NO_TTL


def test_unknown_lane_is_refused() -> None:
    with pytest.raises(LaneNotFound):
        lanes.require("nobody")


def test_a_tab_belongs_to_exactly_one_lane() -> None:
    first, second = lanes.open_lane(), lanes.open_lane()
    lanes.adopt("T1", first)
    assert lanes.tabs_of(first) == ("T1",)
    assert lanes.tabs_of(second) == ()
    lanes.adopt("T1", second)
    assert lanes.tabs_of(first) == ()
    assert lanes.tabs_of(second) == ("T1",)


def test_expiry_needs_quiet_not_merely_age() -> None:
    """The bug this guards: a lane collected while its call was still running.

    A `script` with a 600s budget outlives a 30-minute lane only if nothing
    restarts the clock, so every call touches the lane on entry and on return.
    """
    lane = lanes.open_lane(ttl_s=60)
    assert lanes.expired(now=int(time.time()) + 61) == (lane,)
    lanes.touch(lane)
    # The clock now runs from the touch, not from when the lane was opened.
    assert lanes.expired(now=int(time.time()) + 59) == ()


def test_a_lane_with_no_ttl_never_expires() -> None:
    lane = lanes.open_lane(ttl_s=lanes.NO_TTL)
    assert lane not in lanes.expired(now=int(time.time()) + 10_000)


def test_set_ttl_restarts_the_clock() -> None:
    lane = lanes.open_lane(ttl_s=60)
    lanes.set_ttl(lane, 7200)
    assert lanes.require(lane).ttl_s == 7200
    assert lanes.expired(now=int(time.time()) + 61) == ()


def test_destroying_a_lane_takes_its_rows_with_it() -> None:
    lane = lanes.open_lane()
    lanes.adopt("T1", lane)
    lanes.claim_screen(lane)
    lanes.destroy(lane)
    with pytest.raises(LaneNotFound):
        lanes.require(lane)
    assert lanes.owner("T1") is None
    assert lanes.screen_claims() == ()


def test_reserved_lanes_are_emptied_rather_than_removed() -> None:
    """`destroy_lane('orphan')` reading as success while the lane comes
    straight back on the next call would be a lie."""
    lanes.adopt("T1", lanes.ORPHAN)
    lanes.destroy(lanes.ORPHAN)
    assert lanes.tabs_of(lanes.ORPHAN) == ()
    assert lanes.require(lanes.ORPHAN).id == lanes.ORPHAN


# --- reconciling -------------------------------------------------------


def test_a_tab_chrome_no_longer_holds_is_forgotten() -> None:
    lane = lanes.open_lane()
    lanes.adopt("GONE", lane)
    lanes.reconcile(live=(), opened_by={})
    assert lanes.tabs_of(lane) == ()


def test_a_popup_joins_the_lane_that_opened_it() -> None:
    """window.open and target=_blank, which would otherwise leak.

    Such a target has no row, so no lane can see it, no lane can close it, and
    the sweep never reaches it -- the sweep collects lanes, not tabs.
    """
    lane = lanes.open_lane()
    lanes.adopt("PARENT", lane)
    lanes.reconcile(live=("PARENT", "POPUP"), opened_by={"POPUP": "PARENT"})
    assert lanes.owner("POPUP") == lane


def test_a_tab_with_no_opener_lands_in_orphan() -> None:
    """A human opening tabs during a handoff. Chrome records no opener for
    them, so there is nothing to trace and guessing would be a heuristic."""
    lanes.reconcile(live=("HUMAN",), opened_by={})
    assert lanes.owner("HUMAN") == lanes.ORPHAN


def test_a_popup_whose_opener_is_unknown_lands_in_orphan() -> None:
    lanes.reconcile(live=("POPUP",), opened_by={"POPUP": "VANISHED"})
    assert lanes.owner("POPUP") == lanes.ORPHAN


def test_reconcile_leaves_settled_tabs_where_they_are() -> None:
    lane = lanes.open_lane()
    lanes.adopt("T1", lane)
    lanes.reconcile(live=("T1",), opened_by={"T1": "SOMETHING"})
    assert lanes.owner("T1") == lane


# --- the screen --------------------------------------------------------


def test_the_screen_stays_up_while_another_lane_holds_it() -> None:
    """The interference this replaces: lane A summons a human for a captcha,
    lane B finishes something unrelated and calls hide_browser, and the window
    disappears mid-solve."""
    first, second = lanes.open_lane(), lanes.open_lane()
    lanes.claim_screen(first)
    lanes.claim_screen(second)
    assert lanes.release_screen(second) is False
    assert lanes.release_screen(first) is True


def test_releasing_a_claim_nobody_holds_is_not_an_error() -> None:
    assert lanes.release_screen(lanes.open_lane()) is True


def test_claiming_twice_still_needs_one_release() -> None:
    lane = lanes.open_lane()
    lanes.claim_screen(lane)
    lanes.claim_screen(lane)
    assert lanes.release_screen(lane) is True


# --- closing ------------------------------------------------------------


class _FakeTargets:
    """Chrome's target list, without Chrome. Records what was closed."""

    def __init__(self, ids: tuple[str, ...]) -> None:
        self.ids = list(ids)
        self.closed: list[str] = []

    def pages(self) -> tuple[object, ...]:
        return tuple(type("T", (), {"id": tab})() for tab in self.ids)

    def close(self, tab: str) -> bool:
        self.closed.append(tab)
        self.ids.remove(tab)
        return True

    def openers(self) -> dict[str, str]:
        return {}


@pytest.fixture
def chrome(monkeypatch: pytest.MonkeyPatch) -> _FakeTargets:
    """`lanes` reads Chrome through `targets`, so that is what is replaced."""
    fake = _FakeTargets(("T1", "T2", "T3"))
    monkeypatch.setattr(targets, "pages", fake.pages)
    monkeypatch.setattr(targets, "close", fake.close)
    monkeypatch.setattr(targets, "openers", fake.openers)
    return fake


def test_closing_reaches_only_this_lanes_tabs(chrome: _FakeTargets) -> None:
    mine, theirs = lanes.open_lane(), lanes.open_lane()
    lanes.adopt("T1", mine)
    lanes.adopt("T2", theirs)
    assert lanes.close_tabs(mine, ("T1", "T2")) == 1
    assert chrome.closed == ["T1"]
    assert lanes.tabs_of(theirs) == ("T2",)


def test_the_last_tab_in_the_browser_is_never_closed(
        chrome: _FakeTargets) -> None:
    """Chrome exits when it loses its final tab, taking the daemon and the
    warm session with it.

    The old `close_other_tabs` kept one back by being phrased as "keep that
    one". Under lanes the survivor must belong to nobody in particular, so the
    rule lives here instead, on the one path every close goes through.
    """
    chrome.ids = ["ONLY"]
    lane = lanes.open_lane()
    lanes.adopt("ONLY", lane)
    assert lanes.close_tabs(lane, ("ONLY",)) == 0
    assert chrome.closed == []


def test_a_sweep_collects_an_expired_lane_and_its_tabs(
        chrome: _FakeTargets) -> None:
    stale = lanes.open_lane(ttl_s=1)
    lanes.adopt("T1", stale)
    lanes.adopt("T2", lanes.ORPHAN)
    lanes.adopt("T3", lanes.ORPHAN)
    time.sleep(1.1)
    assert lanes.sweep() == (stale,)
    assert chrome.closed == ["T1"]
    with pytest.raises(LaneNotFound):
        lanes.require(stale)


def test_a_sweep_leaves_orphan_alone_however_old(chrome: _FakeTargets) -> None:
    """A TTL on `orphan` would collect the tabs a human opened during a
    handoff, which is the one thing ticket 018 exists to prevent."""
    lanes.adopt("T1", lanes.ORPHAN)
    time.sleep(1.1)
    assert lanes.sweep() == ()
    assert chrome.closed == []


def test_an_expired_lane_is_refused_rather_than_failing_on_a_dangling_row(
        chrome: _FakeTargets) -> None:
    """The order bug: `require` before `sweep`.

    A lane that expired between calls is still a row, so checking first let it
    through; the sweep then destroyed it underneath the call and the first
    `adopt` hit a foreign key with nothing behind it -- a sqlite IntegrityError
    reaching the caller instead of LANE_NOT_FOUND. Sweeping first makes the
    refusal the one the caller can act on.
    """
    lane = lanes.open_lane(ttl_s=1)
    time.sleep(1.1)
    lanes.sweep()
    with pytest.raises(LaneNotFound):
        lanes.require(lane)
