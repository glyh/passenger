"""agent-browser -- one generic fetch/browse pair over a warm Chrome session."""
import argparse
import json
import sys

from . import browser, challenge, window
from .config import CDP_URL, MIN_CONTENT_WORDS, PROFILE_DIR
from .extract import to_markdown


def _load(page, url: str, wait: str, settle_ms: int):
    page.goto(url, wait_until=wait, timeout=60000)
    page.wait_for_timeout(settle_ms)
    return to_markdown(page.content(), page.url)


def cmd_fetch(args):
    with browser.Session() as s:
        page = s.page(reuse=not args.new_tab)
        text = _load(page, args.url, args.wait, args.settle)
        blocker = challenge.detect(page, len(text.split()), args.min_words)
        if blocker:
            # Evidence is captured for novel blockers either way -- a suppressed
            # handoff is exactly when you most want to know what you hit.
            if not blocker["known"]:
                ev = challenge.capture_evidence(page, blocker)
                sig = challenge.propose_signature(ev)
                blocker["evidence"] = ev.get("screenshot")
                blocker["proposed"] = sig.get("selector") or sig.get("title_re")
                print(f"   novel blocker -- evidence: {ev.get('screenshot')}",
                      file=sys.stderr)
            if args.no_handoff:
                json.dump({"blocked": blocker}, sys.stdout, indent=2)
                sys.exit(2)
            text = challenge.hand_off(page, blocker, to_markdown, args.min_words)
            if text is None:
                sys.exit(2)
        if args.json:
            json.dump({"url": page.url, "title": page.title(),
                       "words": len(text.split()), "markdown": text},
                      sys.stdout, indent=2)
        else:
            print(text)
        if not args.keep_tab and page.url != "about:blank":
            page.goto("about:blank")


def cmd_open(args):
    """Park a URL in the window so you can log in / solve something by hand."""
    with browser.Session() as s:
        page = s.page(reuse=False)
        page.goto(args.url, wait_until="domcontentloaded", timeout=60000)
        window.show()
        page.bring_to_front()
        print(f"opened {args.url} -- log in there; the profile keeps the session.")


def cmd_serve(args):
    browser.start(detach=not args.foreground, hidden=not args.visible)


def cmd_show(args):
    window.show()
    print(f"shown [{window.backend()}]")


def cmd_hide(args):
    print(f"hidden [{window.backend()}]" if window.hide()
          else f"cannot hide on this compositor [{window.backend()}]")


def cmd_stop(args):
    browser.stop()


def cmd_status(args):
    up = browser.is_up()
    print(f"daemon:  {'up' if up else 'down'} ({CDP_URL})")
    print(f"window:  {'visible' if window._visible() else 'hidden'} "
          f"[{window.backend()}]")
    print(f"profile: {PROFILE_DIR}")
    if up:
        with browser.Session() as s:
            for p in s.context.pages:
                print(f"  tab: {p.url[:100]}")


def cmd_signatures(args):
    if args.approve:
        print("approved" if challenge.approve(args.approve) else "no such pending signature")
        return
    if args.forget:
        print("forgotten" if challenge.forget(args.forget) else "no such signature")
        return
    for sig in challenge.signatures(include_pending=True):
        flag = " (pending review)" if sig.get("pending_review") else ""
        cond = sig.get("selector") or sig.get("title_re") or sig.get("url_re")
        print(f"{sig['name']:<40} {sig.get('kind','?'):<10} {cond}{flag}")


def main():
    ap = argparse.ArgumentParser(prog="agent-browser")
    sub = ap.add_subparsers(dest="cmd", required=True)

    f = sub.add_parser("fetch", help="fetch a URL as markdown")
    f.add_argument("url")
    f.add_argument("--json", action="store_true")
    f.add_argument("--new-tab", action="store_true")
    f.add_argument("--keep-tab", action="store_true", help="leave the tab open")
    f.add_argument("--no-handoff", action="store_true",
                   help="exit 2 on a blocker instead of asking for help")
    f.add_argument("--wait", default="domcontentloaded",
                   choices=["load", "domcontentloaded", "networkidle", "commit"])
    f.add_argument("--min-words", type=int, default=MIN_CONTENT_WORDS,
                   help="below this, a page is treated as blocked (0 disables)")
    f.add_argument("--settle", type=int, default=1500,
                   help="ms to let client-side rendering finish")
    f.set_defaults(func=cmd_fetch)

    o = sub.add_parser("open", help="open a URL and leave it for manual login")
    o.add_argument("url"); o.set_defaults(func=cmd_open)

    sv = sub.add_parser("serve", help="start the Chrome daemon")
    sv.add_argument("--foreground", action="store_true")
    sv.add_argument("--visible", action="store_true",
                    help="don't hide the window on a special workspace")
    sv.set_defaults(func=cmd_serve)

    sub.add_parser("show", help="summon the browser window").set_defaults(func=cmd_show)
    sub.add_parser("hide", help="tuck the window away").set_defaults(func=cmd_hide)
    sub.add_parser("stop", help="kill the daemon").set_defaults(func=cmd_stop)
    sub.add_parser("status").set_defaults(func=cmd_status)

    sg = sub.add_parser("signatures", help="list / curate learned signatures")
    sg.add_argument("--approve", metavar="NAME", help="promote a pending signature")
    sg.add_argument("--forget", metavar="NAME", help="delete a signature")
    sg.set_defaults(func=cmd_signatures)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
