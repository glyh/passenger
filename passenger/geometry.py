"""Imperative shell: at what density the nested browser renders.

The *size* of the nested output is no longer decided here. The viewer asks for
it: noVNC sends the RFB `SetDesktopSize` its window needs, wayvnc answers it
through cage's wlr-output-management, and the framebuffer follows the window
continuously -- including while it is being dragged to a new size. Everything
this module used to do to guess that size went with it, along with the race it
could never win: wayvnc advertises a resize to clients some time after
wlr-randr returns, and a viewer connecting inside that gap kept the old shape.

What a viewer cannot ask for is the *scale*, and scale is not cosmetic. It is
what decides whether the nested Chrome treats a 1422x1730 output as 1422x1730
CSS pixels of unreadably small page, or as 889x1081 at dpr 2 -- which is what
an ordinary laptop reports, and what someone reading a captcha needs.

Setting the scale leaves the framebuffer size alone, so unlike the old fitting
it cannot disturb a connected viewer; a live session was watched through a
scale change and back to confirm it.
"""
import os
import shutil
import subprocess

from pydantic import BaseModel, Field

from .config import settings

_HEADLESS_PREFIX = "HEADLESS"


class Scale(BaseModel, frozen=True):
    """How many device pixels the nested Chrome draws per CSS pixel."""

    factor: float = Field(gt=0)


def _run(*args: str, env: dict[str, str] | None = None) -> str:
    """Run a tool and return its stdout, or "" if it could not run at all.

    The environment is layered over the current one rather than replacing it:
    passing a bare dict drops PATH, and the command then cannot be found even
    though it is installed.

    Failures are swallowed because every caller here is improving the picture,
    never keeping the session alive -- a missing tool should cost sharpness,
    not the browser.
    """
    try:
        return subprocess.run(args, capture_output=True, text=True,
                              check=False,
                              env={**os.environ, **env} if env else None).stdout
    except OSError:
        return ""


def configured() -> Scale | None:
    """An explicit scale from the environment, which wins over the probe."""
    if settings.vnc_scale is None:
        return None
    return Scale(factor=settings.vnc_scale)


def host() -> Scale | None:
    """The scale the host screen runs, which the viewer's window inherits.

    wlr-randr first and core `wl_output` second, because the two answer with
    different precision: wl_output carries an integer buffer scale, so a screen
    at 1.6 reads as 2, while wlr-randr reports the compositor's real fractional
    value. The integer is a usable fallback -- Chrome rounds the scale up to an
    integer anyway -- but it is not the same picture.
    """
    for line in _run("wlr-randr").splitlines():
        if line.strip().startswith("Scale:"):
            value = _number(line.split("Scale:")[1])
            if value:
                return Scale(factor=value)
    return _wl_output_scale()


def _wl_output_scale() -> Scale | None:
    """The first output's integer buffer scale, from core wl_output."""
    if not shutil.which("wayland-info"):
        return None
    for line in _first_block(_run("wayland-info")).splitlines():
        # Not startswith: scale shares a line with the position, as
        # `x: 0, y: 0, scale: 2,`.
        if "scale:" in line:
            value = _number(line.split("scale:")[1])
            if value:
                return Scale(factor=value)
    return None


def _first_block(report: str) -> str:
    """The first wl_output stanza, from its header to the next interface.

    Scoped to one output because a second monitor further down the dump
    describes a screen the viewer is not on.
    """
    lines = report.splitlines()
    start = next((i for i, line in enumerate(lines) if "wl_output" in line), None)
    if start is None:
        return ""
    end = next((i for i, line in enumerate(lines[start + 1:], start + 1)
                if line.startswith("interface:")), len(lines))
    return "\n".join(lines[start:end])


def _number(text: str) -> float | None:
    """Leading number of a field like `1.601562` or `2,`."""
    digits = ""
    for char in text.strip():
        if char.isdigit() or (char == "." and "." not in digits):
            digits += char
        elif digits:
            break
    return float(digits) if digits else None


def select() -> Scale | None:
    """The configured scale, or the host screen's, or nothing to say."""
    return configured() or host()


def _output_name(env: dict[str, str]) -> str | None:
    for line in _run("wlr-randr", env=env).splitlines():
        if line.startswith(_HEADLESS_PREFIX):
            return line.split()[0]
    return None


def apply(display: str, scale: Scale) -> str | None:
    """Set the nested output's scale, or None if it could not be set.

    Best effort by design: a failure here costs picture quality, never the
    session, so it is reported rather than raised. Reported honestly, though --
    announcing a scale wlr-randr refused would be the same silent lie the old
    resize told.
    """
    if shutil.which("wlr-randr") is None:
        return None
    env = {"WAYLAND_DISPLAY": display,
           "XDG_RUNTIME_DIR": settings.runtime_dir}
    name = _output_name(env)
    if name is None:
        return None
    try:
        done = subprocess.run(["wlr-randr", "--output", name,
                               "--scale", str(scale.factor)],
                              capture_output=True, text=True, check=False,
                              env={**os.environ, **env})
    except OSError:
        return None
    return None if done.returncode != 0 else f"scale {scale.factor:g}"


def fit(display: str) -> str | None:
    """Give the nested output the density of the screen it will be seen on."""
    scale = select()
    return None if scale is None else apply(display, scale)
