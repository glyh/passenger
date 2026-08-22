"""The passthrough door's core. Pure: no browser, no page."""
import pytest

from ab.errors import ErrorCode, ScriptError
from ab.script import execute


def _run(source: str, page: object = None):
    return execute(source, page, lambda target: "read")


def test_a_script_returns_a_value():
    """`return` at the top level of the source, which plain exec would refuse."""
    assert _run("return 1 + 1") == 2


def test_the_bound_names_are_page_and_read():
    assert _run("return read(page)", page="a page") == "read"


def test_a_handle_is_refused_by_name():
    """Ticket 013: nearly every Playwright call hands back an object that
    cannot be JSON, so the error has to say what to return instead rather than
    surfacing a serialisation traceback."""
    class Locator:
        pass

    with pytest.raises(ScriptError) as refused:
        _run("return page", page=Locator())
    assert refused.value.code is ErrorCode.SCRIPT_RETURN_NOT_JSON
    assert "Locator" in refused.value.message


def test_a_syntax_error_points_at_the_caller_s_own_line():
    """The source is compiled as a function body, so every line moves by one.
    The caller never sees that wrapper and must not see its line numbers."""
    with pytest.raises(ScriptError) as bad:
        _run("x = 1\ny = (")
    assert bad.value.code is ErrorCode.SCRIPT_INVALID
    assert "line 2" in bad.value.message


def test_a_raise_reports_the_line_it_came_from():
    with pytest.raises(ScriptError) as raised:
        _run("a = 1\nb = 2\nraise ValueError('nope')")
    assert raised.value.code is ErrorCode.SCRIPT_RAISED
    assert raised.value.message == "ValueError: nope"
    assert raised.value.detail is not None
    assert "line 3" in raised.value.detail


def test_an_empty_script_is_not_an_error():
    """Nothing to return is a script that ran, not a script that broke."""
    assert _run("") is None
