"""Challenge detection and human handoff.

Two tiers, because a fixed signature list can only ever recognise the challenges
that existed when it was written:

  tier 1  known signatures -- cheap, exact, no false positives
  tier 2  "did I actually get content?" -- the catch-all that notices novel
          challenge types, captures evidence, and proposes a new signature

Nothing here tries to solve a challenge. Auto-solving is what gets a profile
burned; a human solving it once in a persistent profile is both more robust and
the defensible version of this.
"""
import json
import re
import subprocess
import sys
import time

from . import window
from .config import (HANDOFF_TIMEOUT_S, MIN_CONTENT_WORDS, REPORTS_DIR,
                     SIGNATURES_FILE)

BUILTIN = [
    {"name": "cloudflare-interstitial", "kind": "challenge",
     "title_re": r"^(Just a moment|Attention Required|Please Wait)"},
    {"name": "cloudflare-turnstile", "kind": "challenge",
     "selector": "iframe[src*='challenges.cloudflare.com']"},
    {"name": "recaptcha", "kind": "challenge",
     "selector": "iframe[src*='recaptcha/api2/bframe'], iframe[src*='recaptcha/enterprise/bframe']"},
    {"name": "hcaptcha", "kind": "challenge",
     "selector": "iframe[src*='hcaptcha.com'][src*='frame=challenge'], iframe[src*='newassets.hcaptcha.com/captcha']"},
    {"name": "arkose-funcaptcha", "kind": "challenge",
     "selector": "iframe[src*='arkoselabs.com'], iframe[src*='funcaptcha.com']"},
    {"name": "datadome", "kind": "challenge",
     "selector": "iframe[src*='captcha-delivery.com'], #datadome-captcha"},
    {"name": "px-human", "kind": "challenge",
     "selector": "#px-captcha, [id^='px-captcha']"},
    {"name": "login-wall", "kind": "login",
     "url_re": r"/(login|signin|sign-in|sso|auth|accounts/login)(/|\?|$)"},
]


def _load_learned() -> list:
    if not SIGNATURES_FILE.exists():
        return []
    try:
        return json.loads(SIGNATURES_FILE.read_text()).get("learned", [])
    except (json.JSONDecodeError, OSError):
        return []


def _save_learned(learned: list) -> None:
    SIGNATURES_FILE.parent.mkdir(parents=True, exist_ok=True)
    SIGNATURES_FILE.write_text(json.dumps({"learned": learned}, indent=2))


def signatures(include_pending: bool = False) -> list:
    """Pending signatures are proposals, not rules.

    An auto-derived signature is a guess from a single page; letting it match
    before a human confirms it means one false positive poisons every later
    fetch of that site. Promote with: agent-browser signatures --approve NAME
    """
    learned = _load_learned()
    if not include_pending:
        learned = [s for s in learned if not s.get("pending_review")]
    return BUILTIN + learned


def _matches(sig: dict, page, title: str) -> bool:
    """All fields present in the signature must match."""
    if "title_re" in sig and not re.search(sig["title_re"], title, re.I):
        return False
    if "url_re" in sig and not re.search(sig["url_re"], page.url, re.I):
        return False
    if "selector" in sig:
        try:
            if page.locator(sig["selector"]).count() == 0:
                return False
        except Exception:
            return False
    # A signature with no conditions must never match everything.
    return any(k in sig for k in ("title_re", "url_re", "selector"))


def detect(page, word_count: int, min_words: int = MIN_CONTENT_WORDS) -> dict | None:
    """Return a dict describing the blocker, or None if the page looks fine."""
    try:
        title = page.title()
    except Exception:
        title = ""

    for sig in signatures():
        if _matches(sig, page, title):
            return {"name": sig["name"], "kind": sig.get("kind", "challenge"),
                    "known": True, "title": title, "url": page.url}

    if word_count < min_words:
        return {"name": "unknown-blocker", "kind": "unknown", "known": False,
                "title": title, "url": page.url, "word_count": word_count}
    return None


def capture_evidence(page, blocker: dict) -> dict:
    """Dump what a human (or a model) needs to classify a novel blocker."""
    REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    stamp = str(int(time.time()))
    shot = REPORTS_DIR / f"{stamp}.png"
    try:
        page.screenshot(path=str(shot))
    except Exception:
        shot = None

    try:
        frames = page.eval_on_selector_all(
            "iframe", "els => els.map(e => e.src).filter(Boolean).slice(0, 10)")
    except Exception:
        frames = []
    try:
        prompts = page.eval_on_selector_all(
            "h1, h2, button, [role=button], label",
            "els => els.map(e => (e.innerText||'').trim())"
            ".filter(t => t && t.length < 120).slice(0, 15)")
    except Exception:
        prompts = []

    evidence = {**blocker, "iframes": frames, "visible_text": prompts,
                "screenshot": str(shot) if shot else None}
    (REPORTS_DIR / f"{stamp}.json").write_text(json.dumps(evidence, indent=2))
    return evidence


def propose_signature(evidence: dict) -> dict:
    """Turn a novel blocker into a candidate signature for next time.

    Marked pending_review rather than trusted: a guess derived from one page is
    exactly the kind of rule that starts matching things it shouldn't.
    """
    host = re.sub(r"^https?://([^/]+).*", r"\1", evidence.get("url", ""))
    sig = {"name": f"learned-{host}-{int(time.time())}", "kind": "unknown",
           "pending_review": True, "seen_at": evidence.get("url"),
           "evidence": evidence.get("screenshot")}
    for src in evidence.get("iframes", []):
        m = re.match(r"https?://([^/]+)", src)
        # A third-party iframe host is the single most reliable tell.
        if m and m.group(1) not in host:
            sig["selector"] = f"iframe[src*='{m.group(1)}']"
            break
    else:
        if evidence.get("title"):
            sig["title_re"] = "^" + re.escape(evidence["title"][:60])

    learned = _load_learned()
    if not any(s.get("selector") == sig.get("selector") and sig.get("selector")
               for s in learned):
        learned.append(sig)
        _save_learned(learned)
    return sig


def hand_off(page, blocker: dict, extract_fn,
             min_words: int = MIN_CONTENT_WORDS) -> str | None:
    """Ask the human to solve it, then wait for the page to come good.

    Returns the extracted text once the block clears, or None on timeout.
    """
    label = blocker["name"]
    msg = f"[{label}] needs you: {blocker['url']}"
    print(f"\n!! {msg}", file=sys.stderr)
    was_hidden = not window._visible()
    window.show()
    try:
        page.bring_to_front()
    except Exception:
        pass
    subprocess.run(["notify-send", "-u", "critical", "Agent browser needs you", msg],
                   check=False)
    print(f"   solve it in the Chrome window; waiting up to {HANDOFF_TIMEOUT_S}s...",
          file=sys.stderr)

    deadline = time.time() + HANDOFF_TIMEOUT_S
    while time.time() < deadline:
        time.sleep(2)
        try:
            text = extract_fn(page.content(), page.url)
            words = len(text.split())
            if detect(page, words, min_words) is None:
                print(f"   resolved ({words} words)\n", file=sys.stderr)
                if was_hidden:
                    window.hide()
                return text
        except Exception:
            continue  # mid-navigation; try again
    print("   timed out waiting for you\n", file=sys.stderr)
    if was_hidden:
        window.hide()
    return None


def approve(name: str) -> bool:
    learned = _load_learned()
    for s in learned:
        if s["name"] == name and s.pop("pending_review", None) is not None:
            _save_learned(learned)
            return True
    return False


def forget(name: str) -> bool:
    learned = _load_learned()
    kept = [s for s in learned if s["name"] != name]
    if len(kept) != len(learned):
        _save_learned(kept)
        return True
    return False
