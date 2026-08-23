"""Imperative shell: which lane owns which tab, and when a lane's time is up.

Before this, tabs were one global pile with no owner. `close_tabs` took no
argument and closed everything but a blank keeper, and `page(reuse=True)`
handed back *any* `about:blank` it found -- so one caller closed the tab
another was driving, and one caller's fetch was given the blank tab another had
just opened. Both are reachable with two agents and no exotic setup: the MCP
server is stdio, so two sessions are two processes sharing one Chrome, and
subagents inside one session share a single process *and* connection, which
means the transport cannot tell apart the parties most likely to collide.

A lane is a scope of ownership with a lifetime. Tabs open inside it, only it
can see or close them, and when its clock runs out they go. It is not `sink`:
a sink is where a stream goes to die, and this is neither a destination nor
final. See ticket 040.

**Why sqlite.** Two `passenger-mcp` processes write this concurrently, so an
in-process dict is not merely a restart hazard -- it is invisible to the other
writer, which would leave each process believing it owned every tab. sqlite is
stdlib, gives real transactions instead of a hand-rolled lock file, and follows
the idiom `session.py` already set: the shell keeps the one record that knows a
correlation nothing else in the system does.

**Why not a BrowserContext per lane.** That is the elegant answer and it is
disqualified. Membership would live inside Chrome and be readable by any
process for free, and Chrome would enforce isolation rather than this table.
But CDP browser contexts are incognito-like -- separate cookie jar, separate
storage -- and the one warm logged-in profile is the entire point of the tool.
Written down so it is not rediscovered as a good idea.

**Chrome owns existence; this owns ownership.** A row here is meaningful only
while `/json/list` still reports the target. Target ids are not reused across a
Chrome restart, so the table is dropped when the daemon starts (`browser.start`)
rather than carrying an epoch column: there is no reading of an old epoch that
is ever useful.
"""
import secrets
import sqlite3
import time
from contextlib import contextmanager
from typing import Iterator

from pydantic import BaseModel, Field

from . import targets
from .config import STATE_DIR
from .errors import LaneNotFound

DB_FILE = STATE_DIR / "lanes.db"

# The reserved lanes. Both are rows like any other -- same table, same sweep --
# and differ only in having a fixed, guessable id instead of a minted one.
#
# `cli` exists because a human at a terminal runs `passenger fetch <url>` and
# then `passenger script --tab <id>` thirty seconds later, from two separate
# processes. A minted id would have to be copied by hand; a lane per invocation
# would break the second command outright.
#
# `orphan` holds tabs nothing else can claim -- overwhelmingly the ones a human
# opened during a handoff, which have no opener to trace. Any caller may read
# and close it, which makes it a junk drawer and it is documented as one: an
# agent can empty it while a human is mid-login.
CLI = "cli"
ORPHAN = "orphan"

DEFAULT_TTL_S = 1800
# `orphan` keeps its tabs forever. A TTL there would auto-close a human's
# half-finished login, which is the one thing ticket 018 exists to prevent.
NO_TTL = 0

_SCHEMA = """
CREATE TABLE IF NOT EXISTS lanes (
  id         TEXT PRIMARY KEY,
  ttl_s      INTEGER NOT NULL,
  touched_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS tabs (
  tab  TEXT PRIMARY KEY,
  lane TEXT NOT NULL REFERENCES lanes(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS screen_claims (
  lane TEXT PRIMARY KEY REFERENCES lanes(id) ON DELETE CASCADE
);
"""


class Lane(BaseModel, frozen=True):
    """One lane, as the table holds it."""

    id: str
    # Seconds of quiet before the lane and its tabs go. NO_TTL means never.
    ttl_s: int = Field(ge=0)
    # Wall clock, not monotonic: monotonic does not cross processes, and two
    # processes are exactly who reads this.
    touched_at: int

    def expired_at(self, now: int) -> bool:
        return self.ttl_s != NO_TTL and now - self.touched_at >= self.ttl_s


@contextmanager
def _db() -> Iterator[sqlite3.Connection]:
    """One connection, with the schema and the reserved lanes guaranteed.

    WAL because the other writer is another process, and `foreign_keys` because
    the cascade from `lanes` to `tabs` and `screen_claims` is what keeps a
    destroyed lane from leaving rows that name it.
    """
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(DB_FILE, timeout=10, isolation_level=None)
    try:
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA foreign_keys=ON")
        connection.executescript(_SCHEMA)
        _ensure(connection, CLI, DEFAULT_TTL_S)
        _ensure(connection, ORPHAN, NO_TTL)
        yield connection
    finally:
        connection.close()


def _ensure(connection: sqlite3.Connection, lane: str, ttl_s: int) -> None:
    connection.execute(
        "INSERT OR IGNORE INTO lanes (id, ttl_s, touched_at) VALUES (?, ?, ?)",
        (lane, ttl_s, int(time.time())))


def reset() -> None:
    """Forget everything. Called when a fresh Chrome starts.

    Not a migration and not a repair: every row here names a CDP target id
    from a browser that is gone, and those ids are never handed out again.
    """
    with _db() as connection:
        connection.executescript(
            "DROP TABLE IF EXISTS screen_claims;"
            "DROP TABLE IF EXISTS tabs;"
            "DROP TABLE IF EXISTS lanes;")


def open_lane(ttl_s: int = DEFAULT_TTL_S) -> str:
    """Mint a lane and return its id.

    Server-side rather than caller-named. A caller-chosen name saves one round
    trip and collides the moment two subagents of one session both pick
    "scratch", which is the failure this whole mechanism exists to remove.
    """
    lane = secrets.token_hex(8)
    with _db() as connection:
        _ensure(connection, lane, ttl_s)
    return lane


def require(lane: str) -> Lane:
    """The lane, or LaneNotFound. Every lane-taking call starts here."""
    with _db() as connection:
        row = connection.execute(
            "SELECT id, ttl_s, touched_at FROM lanes WHERE id = ?",
            (lane,)).fetchone()
    if row is None:
        raise LaneNotFound(lane)
    return Lane(id=row[0], ttl_s=row[1], touched_at=row[2])


def touch(lane: str) -> None:
    """Restart the lane's clock.

    Called on entry *and* on return of every call naming the lane, because a
    `script` with a 600s budget or a `show_browser` with a 900s wait must not
    expire underneath itself.
    """
    with _db() as connection:
        connection.execute("UPDATE lanes SET touched_at = ? WHERE id = ?",
                           (int(time.time()), lane))


def set_ttl(lane: str, seconds: int) -> None:
    """Change how long this lane may sit quiet, and restart its clock."""
    require(lane)
    with _db() as connection:
        connection.execute(
            "UPDATE lanes SET ttl_s = ?, touched_at = ? WHERE id = ?",
            (max(seconds, 0), int(time.time()), lane))


def adopt(tab: str, lane: str) -> None:
    """Record that this tab belongs to this lane, moving it if it did not."""
    with _db() as connection:
        connection.execute(
            "INSERT INTO tabs (tab, lane) VALUES (?, ?) "
            "ON CONFLICT(tab) DO UPDATE SET lane = excluded.lane", (tab, lane))


def owner(tab: str) -> str | None:
    with _db() as connection:
        row = connection.execute("SELECT lane FROM tabs WHERE tab = ?",
                                 (tab,)).fetchone()
    return None if row is None else str(row[0])


def tabs_of(lane: str) -> tuple[str, ...]:
    with _db() as connection:
        rows = connection.execute("SELECT tab FROM tabs WHERE lane = ?",
                                  (lane,)).fetchall()
    return tuple(str(row[0]) for row in rows)


def forget(*tabs: str) -> None:
    """Drop rows for tabs that are gone. Closing is somebody else's job."""
    with _db() as connection:
        connection.executemany("DELETE FROM tabs WHERE tab = ?",
                               [(tab,) for tab in tabs])


def destroy(lane: str) -> None:
    """Remove the lane. Its tab and claim rows cascade.

    The caller closes the tabs first. A lane removed while its tabs are still
    open would leave them with no owner, no clock and no caller who can see
    them -- permanently unreachable, which is worse than the pile this
    replaces.
    """
    if lane in (CLI, ORPHAN):
        # Reserved lanes are emptied, never removed: the next call would
        # recreate them anyway, and `destroy_lane('orphan')` reading as
        # success while the lane came straight back is a lie.
        with _db() as connection:
            connection.execute("DELETE FROM tabs WHERE lane = ?", (lane,))
        return
    with _db() as connection:
        connection.execute("DELETE FROM lanes WHERE id = ?", (lane,))


def expired(now: int | None = None) -> tuple[str, ...]:
    at = int(time.time()) if now is None else now
    with _db() as connection:
        rows = connection.execute(
            "SELECT id FROM lanes WHERE ttl_s != 0 AND ? - touched_at >= ttl_s",
            (at,)).fetchall()
    return tuple(str(row[0]) for row in rows)


# --- the screen ---------------------------------------------------------
#
# Lanes divide tabs. They do not divide the compositor, the VNC server or the
# viewer window, and `hide_browser()` used to take no arguments and dismiss the
# presenter globally -- so lane A summoning a human for a captcha and lane B
# calling `hide_browser` thirty seconds later took the window away mid-solve.
# That is one lane interrupting another, which is the thing lanes are for.
#
# So the screen is refcounted: a claim per lane, and the viewer comes down when
# the last one goes. It turns `hide_browser` from a global verb into "I am done
# with it", which is what the caller means by it anyway.


def claim_screen(lane: str) -> None:
    with _db() as connection:
        connection.execute(
            "INSERT OR IGNORE INTO screen_claims (lane) VALUES (?)", (lane,))


def release_screen(lane: str) -> bool:
    """Drop this lane's claim. True when nobody is left holding the screen."""
    with _db() as connection:
        connection.execute("DELETE FROM screen_claims WHERE lane = ?", (lane,))
        row = connection.execute("SELECT COUNT(*) FROM screen_claims").fetchone()
    return int(row[0]) == 0


def screen_claims() -> tuple[str, ...]:
    with _db() as connection:
        rows = connection.execute("SELECT lane FROM screen_claims").fetchall()
    return tuple(str(row[0]) for row in rows)


# --- reconciling with Chrome --------------------------------------------


def reconcile(live: tuple[str, ...], opened_by: dict[str, str]) -> None:
    """Make the table agree with what Chrome actually holds.

    Two directions. Rows for tabs that are gone are dropped -- they are dead
    weight, and a stale row would make `list_tabs` promise a tab that closed.
    And targets with no row are attributed: to the lane of whichever tab opened
    them when Chrome says one did, otherwise to `orphan`.

    Adoption by opener is what keeps `window.open` and `target="_blank"` from
    leaking. Such a target has no row, so nobody can see it, nobody can close
    it, and the sweep never reaches it -- the sweep collects lanes, not tabs.
    """
    with _db() as connection:
        known = {str(row[0]): str(row[1]) for row in
                 connection.execute("SELECT tab, lane FROM tabs").fetchall()}
        gone = tuple(tab for tab in known if tab not in live)
        connection.executemany("DELETE FROM tabs WHERE tab = ?",
                               [(tab,) for tab in gone])
        for closed in gone:
            del known[closed]
        for tab in live:
            if tab in known:
                continue
            # An opener whose own row is missing means a chain of popups seen
            # out of order; `orphan` is the honest answer rather than a guess.
            lane = known.get(opened_by.get(tab, ""), ORPHAN)
            connection.execute("INSERT INTO tabs (tab, lane) VALUES (?, ?)",
                               (tab, lane))
            known[tab] = lane


def sweep() -> tuple[str, ...]:
    """Reconcile, then collect every lane whose clock ran out. Returns which.

    Opportunistic: run at the top of any call that touches the registry, so
    there is no background thread and nothing to keep alive. Same shape as
    `session.reap_stale`, which runs when the daemon starts for the same
    reason.

    Closing goes through the CDP HTTP endpoint rather than patchright, so tab
    bookkeeping keeps working when a renderer does not -- and so that a sweep
    at the top of every call does not pay for an attach that initialises every
    open tab.
    """
    try:
        live = tuple(page.id for page in targets.pages())
    except Exception:
        return ()  # no daemon, or it is not answering; nothing to reconcile
    reconcile(live, targets.openers())
    dead = expired()
    for lane in dead:
        close_tabs(lane, tabs_of(lane))
        destroy(lane)
    return dead


def close_tabs(lane: str, tabs: tuple[str, ...]) -> int:
    """Close these tabs of this lane, and forget them. Returns how many went.

    **The last tab is never closed.** Chrome exits when it loses its final tab,
    which would take the daemon and the warm session with it -- the reason the
    old `close_other_tabs` was phrased as "keep that one" rather than "close
    all". Under lanes that phrasing no longer works, because the survivor must
    belong to nobody in particular, so the rule becomes an invariant here
    instead: whatever is asked for, one page stays. It lands in `orphan` on the
    next reconcile, which is the correct home for a tab that exists only so
    Chrome keeps running.
    """
    mine = set(tabs_of(lane))
    doomed = [tab for tab in tabs if tab in mine]
    try:
        live = [page.id for page in targets.pages()]
    except Exception:
        return 0
    if len(doomed) >= len(live):
        # Would empty the browser. Hold one back rather than closing it and
        # racing to open a replacement before Chrome notices.
        doomed = doomed[:len(live) - 1]
    closed = 0
    for tab in doomed:
        if targets.close(tab):
            closed += 1
        forget(tab)
    return closed


def counts() -> tuple[int, int]:
    """Total pages Chrome holds, and how many are in `orphan`.

    The one number that reveals a lane you do not own. A caller sees only its
    own tabs, so without this there is no view anywhere in the tool that shows
    tabs piling up -- and this map began with a stack that was silently broken
    while every status read healthy. A count is a measurement; ids and owners
    would be a listing, which is the side of the line agents stay off.
    """
    try:
        live = tuple(page.id for page in targets.pages())
    except Exception:
        return 0, 0
    return len(live), len([tab for tab in tabs_of(ORPHAN) if tab in live])
