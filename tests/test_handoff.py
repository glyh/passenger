"""Waiting on a human, and the one presenter that cannot be waited on.

The scar is a design one, caught while building ticket 018 rather than in
production: `presented()` is a real observation only for the local presenter.
`LinkPresenter` and `NullPresenter` answer `False` unconditionally, because
whether anyone opened a URL handed to them is unknowable from here -- so a
wait built on "the viewer closed" would report success the instant it began,
on exactly the deployments that most need a human. The refusal is the fix, and
this is what stops it being quietly removed as a redundant branch.
"""
import passenger.handoff as handoff
from passenger.models import PresenterName


class _Fake:
    """A presenter whose window state is whatever the test says it is."""

    def __init__(self, name: PresenterName, observes: bool,
                 closes_after: int | None = None) -> None:
        self.name = name
        self.observes_presence = observes
        self._closes_after = closes_after
        self._polls = 0

    def available(self) -> bool:
        return True

    def present(self) -> str:
        return "presented"

    def dismiss(self) -> None:
        return None

    def presented(self) -> bool:
        self._polls += 1
        if self._closes_after is None:
            return True
        return self._polls < self._closes_after


def test_a_presenter_that_cannot_see_its_window_refuses_the_wait() -> None:
    presenter = _Fake(PresenterName.WEB, observes=False)
    answer = handoff.wait_for_dismissal(presenter, timeout_s=300)
    assert "cannot wait" in answer
    assert "web" in answer
    # And it refused instantly rather than sleeping out the budget.
    assert presenter._polls == 0


def test_the_wait_ends_when_the_human_closes_the_viewer(monkeypatch) -> None:
    monkeypatch.setattr(handoff, "_POLL_INTERVAL_S", 0.01)
    presenter = _Fake(PresenterName.LOCAL, observes=True, closes_after=3)
    assert "viewer closed" in handoff.wait_for_dismissal(presenter, timeout_s=5)


def test_a_viewer_left_open_times_out_without_claiming_otherwise(monkeypatch) -> None:
    monkeypatch.setattr(handoff, "_POLL_INTERVAL_S", 0.01)
    presenter = _Fake(PresenterName.LOCAL, observes=True)
    assert handoff.wait_for_dismissal(presenter, timeout_s=1).startswith(
        "still open")
