"""Imperative shell: how large the nested output is, and at what scale.

cage's headless output is born 1280x720 at scale 1, which has nothing to do
with the screen it is eventually looked at on. Left alone, a human taking over
the browser gets the worst of both: the frame is letterboxed inside their
window, and every pixel of it is resampled on the way to a HiDPI panel --
precisely when they are being asked to read a captcha or a login form.

The output is therefore resized to fit whoever is about to look at it. cage
implements wlr-output-management, so this is a supported runtime
reconfiguration rather than a restart.

Client-driven resize would be the tidier mechanism -- the viewer knows its own
window, and wayvnc resizes automatically by default -- but it does not work
here: wlvncc never asks, and a client that does ask (TigerVNC with
RemoteResize) is answered `SetDesktopSize failed`. So the size is set from
this side.

The size comes from the screen rather than from the viewer's window. The
window would be the exact target, but measuring another client's window is
not something any Wayland protocol offers, and the compositor IPC that would
answer it differs per desktop -- this tool stays out of the host compositor
on purpose. Each probe is asked whether it is available, and when none is,
the output simply keeps the size it had.
"""
import os
import shutil
import subprocess
from typing import Protocol, runtime_checkable

from pydantic import BaseModel, Field

from .config import settings

_HEADLESS_PREFIX = "HEADLESS"


class Screen(BaseModel, frozen=True):
    """A target output size, in physical pixels, plus its scale factor.

    Physical rather than logical because that is what the VNC client
    receives: matching it to the viewer's window is what removes the border,
    and matching the scale is what makes Chrome render at the density the
    panel actually has.
    """

    width: int = Field(ge=1)
    height: int = Field(ge=1)
    scale: float = Field(default=1.0, gt=0)


@runtime_checkable
class GeometryProbe(Protocol):
    """A way of finding out how big the output should be."""

    def available(self) -> bool: ...
    def target(self) -> Screen | None: ...


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


class ConfiguredScreen:
    """An explicit size from the environment.

    Wins over anything probed: someone who has said what they want is not
    asking for a guess, and it is the only mechanism available on a
    compositor none of the probes understand.
    """

    def available(self) -> bool:
        return settings.vnc_size is not None

    def target(self) -> Screen | None:
        if settings.vnc_size is None:
            return None
        width, _, height = settings.vnc_size.partition("x")
        try:
            return Screen(width=int(width), height=int(height),
                          scale=settings.vnc_scale or 1.0)
        except ValueError:
            return None


class GeometryCommand:
    """A command the user supplies that prints the size to use.

    The exact target is the viewer's own window, and nothing portable can
    measure it: no Wayland protocol exposes another client's geometry, and
    the IPC that would answer it is different on every desktop. Rather than
    picking one desktop and calling it support, the question is handed back
    to whoever knows their own -- they configure a command, and this stays
    ignorant of which compositor answered it.

    Output is `WIDTH x HEIGHT` with an optional `@SCALE`, in physical pixels:

        AGENT_BROWSER_GEOMETRY_CMD='...' agent-browser show
    """

    def available(self) -> bool:
        return settings.geometry_cmd is not None

    def target(self) -> Screen | None:
        if settings.geometry_cmd is None:
            return None
        return parse_geometry(_shell(settings.geometry_cmd))


def parse_geometry(text: str) -> Screen | None:
    """Parse `WxH` or `WxH@scale`. Returns None for anything unrecognised."""
    cleaned = text.strip().lower().replace(" ", "")
    if not cleaned:
        return None
    size, _, scale_text = cleaned.partition("@")
    width, _, height = size.partition("x")
    try:
        return Screen(width=int(width), height=int(height),
                      scale=float(scale_text) if scale_text else 1.0)
    except ValueError:
        return None


def _shell(command: str) -> str:
    try:
        return subprocess.run(command, shell=True, capture_output=True,
                              text=True, check=False).stdout
    except OSError:
        return ""


class HostOutput:
    """The screen this machine actually has, read from core Wayland.

    `wl_output` is part of the core protocol, so every compositor advertises
    it -- wlroots, GNOME, KDE alike. That matters more here than precision:
    the viewer's own window would be the exact target, but no protocol lets
    one client measure another's window, and reaching for a compositor's
    private IPC to find out would tie this tool to one desktop.

    So the output is sized to the whole screen. A viewer shown fullscreen
    then maps pixel for pixel; a viewer in a tile still letterboxes, and
    AGENT_BROWSER_VNC_SIZE is the lever for that case.
    """

    def available(self) -> bool:
        return bool(shutil.which("wayland-info"))

    def target(self) -> Screen | None:
        report = _run("wayland-info")
        if "wl_output" not in report:
            return None
        return self._first_output(report)

    def _first_output(self, report: str) -> Screen | None:
        """Parse the first output that states a current mode.

        The report is a human-readable dump rather than a stable format, so
        this reads only the two fields it needs and gives up quietly if they
        are not where it expects -- a wrong guess here would resize the
        session to something nobody asked for.
        """
        scale = 1.0
        for line in report.splitlines():
            stripped = line.strip()
            # Not startswith: scale shares a line with the position, as
            # `x: 0, y: 0, scale: 2,`.
            if "scale:" in stripped:
                scale = _number(stripped.split("scale:")[1]) or scale
            if stripped.startswith("width:") and "height:" in stripped:
                width = _number(stripped.split("width:")[1])
                height = _number(stripped.split("height:")[1])
                if width and height:
                    return Screen(width=int(width), height=int(height),
                                  scale=scale)
        return None


def _number(text: str) -> float | None:
    """Leading number of a field like `2880 px,` or `2,`."""
    digits = ""
    for char in text.strip():
        if char.isdigit() or (char == "." and "." not in digits):
            digits += char
        elif digits:
            break
    return float(digits) if digits else None


def select() -> Screen | None:
    """First probe that both exists and has an answer."""
    for probe in (ConfiguredScreen(), GeometryCommand(), HostOutput()):
        if not probe.available():
            continue
        target = probe.target()
        if target is not None:
            return target
    return None


def _output_name(env: dict[str, str]) -> str | None:
    for line in _run("wlr-randr", env=env).splitlines():
        if line.startswith(_HEADLESS_PREFIX):
            return line.split()[0]
    return None


def apply(display: str, screen: Screen) -> str | None:
    """Resize the nested output. Returns what changed, or None if it could not.

    Best effort by design: a failure here costs picture quality, never the
    session, so it is reported rather than raised.
    """
    if shutil.which("wlr-randr") is None:
        return None
    env = {"WAYLAND_DISPLAY": display,
           "XDG_RUNTIME_DIR": settings.runtime_dir}
    name = _output_name(env)
    if name is None:
        return None
    _run("wlr-randr", "--output", name,
         "--custom-mode", f"{screen.width}x{screen.height}",
         "--scale", str(screen.scale), env=env)
    return f"{screen.width}x{screen.height} @ {screen.scale:g}"


def fit(display: str) -> str | None:
    """Size the output to whoever is about to look at it."""
    screen = select()
    return None if screen is None else apply(display, screen)
