"""Functional core: turning caller-supplied source into a value.

The one door onto the browser is a script, not a tool per verb (ticket 004),
so this module owns the two things that door needs: getting the source to run
with `return` in it, and deciding what may come back out.

Nothing here touches a browser. It is handed a page and a reader by the shell
and never learns what they are, which is what makes it testable without one.
"""
import json
import textwrap
from typing import Any

from .errors import ErrorCode, ScriptError

# The source is compiled as a function body rather than as a module, because a
# script's last act is nearly always to hand something back and `return` at
# module level is a SyntaxError. The cost is one line of offset in every
# traceback, paid back in `where()`.
#
# `page` is the only name bound. `read` used to be bound beside it -- this
# project's own extraction, in scope for the caller to call. Ticket 046 retired
# it along with `fetch`: reading a page is a judgement, and judgement is the
# caller's. The walker survives as a recipe in the skill, pasted into a script
# by an agent that wants it.
_HEADER = "def __script__(page):\n"

def execute(source: str, page: Any) -> Any:
    """Run the script and return what it returned, checked.

    Raises ScriptError for the three ways this goes wrong -- source that will
    not compile, a script that raised, and a value that cannot leave -- each
    naming which one it was, since the caller's next move differs for each.
    """
    namespace: dict[str, Any] = {}
    exec(_compile(source), namespace)  # noqa: S102 -- running this is the point
    try:
        returned = namespace["__script__"](page)
    except Exception as raised:
        raise ScriptError(
            ErrorCode.SCRIPT_RAISED,
            f"{type(raised).__name__}: {raised}".splitlines()[0],
            detail=where(raised, source)) from raised
    return crossable(returned)


def _compile(source: str) -> Any:
    body = textwrap.indent(source.strip("\n"), "    ") or "    pass"
    try:
        return compile(_HEADER + body + "\n", "<script>", "exec")
    except SyntaxError as bad:
        line = (bad.lineno or 2) - 1
        raise ScriptError(ErrorCode.SCRIPT_INVALID, f"{bad.msg} (line {line})",
                          detail=_line_of(source, line)) from bad


def crossable(value: Any) -> Any:
    """A tool result is JSON. Playwright hands back handles, which are not.

    Returning a Locator or an ElementHandle is the obvious mistake to make
    against an API where nearly every call returns one, so it gets an error
    that says what to return instead rather than a serialisation traceback.
    """
    try:
        json.dumps(value)
    except (TypeError, ValueError):
        raise ScriptError(
            ErrorCode.SCRIPT_RETURN_NOT_JSON,
            f"a {type(value).__name__} cannot cross the tool boundary",
            detail="return what you wanted from it instead -- page.url, "
                   "locator.inner_text(), a list of hrefs") from None
    return value


def where(raised: BaseException, source: str) -> str:
    """The script's own lines out of a traceback that also holds this file.

    Reported against the source the caller sent, not the function it was
    wrapped in, so the line numbers are the ones they can see.
    """
    import traceback

    lines = []
    for frame in traceback.extract_tb(raised.__traceback__):
        if frame.filename != "<script>" or frame.lineno is None:
            continue
        number = frame.lineno - 1
        lines.append(f"line {number}: {_line_of(source, number)}")
    return "\n".join(lines)


def _line_of(source: str, number: int) -> str:
    body = source.strip("\n").splitlines()
    if 1 <= number <= len(body):
        return body[number - 1].strip()
    return ""
