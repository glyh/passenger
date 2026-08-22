"""Imperative shell: telling a human they're needed.

A desktop notification only reaches someone sitting at this machine. In a
container -- or on a server -- the same event has to travel differently, so the
mechanism is a Protocol rather than a hardcoded notify-send.
"""
import json
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from typing import Protocol, runtime_checkable

from .config import settings

_WEBHOOK_TIMEOUT_S = 5


@runtime_checkable
class Notifier(Protocol):
    def notify(self, title: str, message: str) -> None: ...


class StderrNotifier:
    """Always available, and the only one guaranteed to be seen in a pipeline."""

    def notify(self, title: str, message: str) -> None:
        print(f"\n!! {title}: {message}", file=sys.stderr)


class DesktopNotifier:
    def notify(self, title: str, message: str) -> None:
        subprocess.run(["notify-send", "-u", "critical", title, message],
                       check=False)


class WebhookNotifier:
    """POSTs to whatever AGENT_BROWSER_WEBHOOK points at -- ntfy, Slack, etc.

    This is what makes a headless deployment usable: the browser can be on a
    server and still reach you when a challenge needs solving.
    """

    def __init__(self, url: str) -> None:
        self.url = url

    def notify(self, title: str, message: str) -> None:
        payload = json.dumps({"title": title, "text": message,
                              "message": message}).encode()
        request = urllib.request.Request(
            self.url, data=payload,
            headers={"Content-Type": "application/json"})
        try:
            urllib.request.urlopen(request, timeout=_WEBHOOK_TIMEOUT_S).close()
        except (urllib.error.URLError, OSError) as exc:
            print(f"   webhook failed: {exc}", file=sys.stderr)


class FanOutNotifier:
    def __init__(self, *targets: Notifier) -> None:
        self.targets = targets

    def notify(self, title: str, message: str) -> None:
        for target in self.targets:
            target.notify(title, message)


def select() -> Notifier:
    """Stderr always, plus whatever else can actually reach the user."""
    targets: list[Notifier] = [StderrNotifier()]
    if shutil.which("notify-send") is not None:
        targets.append(DesktopNotifier())
    if settings.webhook_url is not None:
        targets.append(WebhookNotifier(settings.webhook_url))
    return FanOutNotifier(*targets)
