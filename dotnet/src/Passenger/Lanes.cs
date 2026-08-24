// Imperative shell: which lane owns which tab, and when a lane's time is up.
//
// Before this, tabs were one global pile with no owner. `close_tabs` took no
// argument and closed everything but a blank keeper, and `page(reuse=true)`
// handed back *any* `about:blank` it found -- so one caller closed the tab
// another was driving, and one caller's fetch was given the blank tab another had
// just opened. Both are reachable with two agents and no exotic setup: the MCP
// server is stdio, so two sessions are two processes sharing one Chrome, and
// subagents inside one session share a single process *and* connection, which
// means the transport cannot tell apart the parties most likely to collide.
//
// A lane is a scope of ownership with a lifetime. Tabs open inside it, only it
// can see or close them, and when its clock runs out they go. It is not `sink`:
// a sink is where a stream goes to die, and this is neither a destination nor
// final. See ticket 040.
//
// **Why sqlite.** Two `passenger-mcp` processes write this concurrently, so an
// in-process dictionary is not merely a restart hazard -- it is invisible to the
// other writer, which would leave each process believing it owned every tab.
// sqlite gives real transactions instead of a hand-rolled lock file, and follows
// the idiom NestedSessions already set: the shell keeps the one record that knows
// a correlation nothing else in the system does.
//
// **Why not a BrowserContext per lane.** That is the elegant answer and it is
// disqualified. Membership would live inside Chrome and be readable by any
// process for free, and Chrome would enforce isolation rather than this table.
// But CDP browser contexts are incognito-like -- separate cookie jar, separate
// storage -- and the one warm logged-in profile is the entire point of the tool.
// Written down so it is not rediscovered as a good idea.
//
// **Chrome owns existence; this owns ownership.** A row here is meaningful only
// while `/json/list` still reports the target. Target ids are not reused across a
// Chrome restart, so the table is dropped when the daemon starts (`Browser.Start`)
// rather than carrying an epoch column: there is no reading of an old epoch that
// is ever useful.

using System.Security.Cryptography;
using Microsoft.Data.Sqlite;

namespace Passenger;

/// <summary>One lane, as the table holds it.</summary>
public sealed record Lane
{
    public required string Id { get; init; }

    /// <summary>Seconds of quiet before the lane and its tabs go. NoTtl means never.</summary>
    public required int TtlS { get; init; }

    /// <summary>
    /// Wall clock, not monotonic: monotonic does not cross processes, and two
    /// processes are exactly who reads this.
    /// </summary>
    public required long TouchedAt { get; init; }

    public bool ExpiredAt(long now) => TtlS != Lanes.NoTtl && now - TouchedAt >= TtlS;
}

public static class Lanes
{
    public static string DbFile => Path.Combine(Config.StateDir, "lanes.db");

    // The reserved lanes. Both are rows like any other -- same table, same sweep --
    // and differ only in having a fixed, guessable id instead of a minted one.
    //
    // `cli` exists because a human at a terminal runs `passenger open <url>` and
    // then `passenger script --tab <id>` thirty seconds later, from two separate
    // processes. A minted id would have to be copied by hand; a lane per invocation
    // would break the second command outright.
    //
    // `orphan` holds tabs nothing else can claim -- overwhelmingly the ones a human
    // opened during a handoff, which have no opener to trace. Any caller may read
    // and close it, which makes it a junk drawer and it is documented as one: an
    // agent can empty it while a human is mid-login.
    public const string Cli = "cli";
    public const string Orphan = "orphan";

    public const int DefaultTtlS = 1800;

    /// <summary>
    /// `orphan` keeps its tabs forever. A TTL there would auto-close a human's
    /// half-finished login, which is the one thing ticket 018 exists to prevent.
    /// </summary>
    public const int NoTtl = 0;

    private const string Schema = """
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
        """;

    private static long Now() => DateTimeOffset.UtcNow.ToUnixTimeSeconds();

    /// <summary>
    /// One connection, with the schema and the reserved lanes guaranteed.
    ///
    /// WAL because the other writer is another process, and `foreign_keys` because
    /// the cascade from `lanes` to `tabs` and `screen_claims` is what keeps a
    /// destroyed lane from leaving rows that name it.
    /// </summary>
    private static SqliteConnection Open()
    {
        Directory.CreateDirectory(Config.StateDir);
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = DbFile,
            Mode = SqliteOpenMode.ReadWriteCreate,
            // The default timeout is zero, which turns the second writer's
            // contention into an immediate "database is locked" rather than a
            // wait. Two MCP processes writing this concurrently is the normal
            // case, not the exotic one.
            DefaultTimeout = 10,
        }.ToString());
        connection.Open();
        Execute(connection, "PRAGMA journal_mode=WAL");
        Execute(connection, "PRAGMA foreign_keys=ON");
        Execute(connection, Schema);
        Ensure(connection, Cli, DefaultTtlS);
        Ensure(connection, Orphan, NoTtl);
        return connection;
    }

    private static void Execute(SqliteConnection connection, string sql,
                                params (string Name, object? Value)[] parameters)
    {
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = sql;
        foreach ((string name, object? value) in parameters)
        {
            command.Parameters.AddWithValue(name, value ?? DBNull.Value);
        }

        command.ExecuteNonQuery();
    }

    private static void Ensure(SqliteConnection connection, string lane, int ttlS) =>
        Execute(connection,
                "INSERT OR IGNORE INTO lanes (id, ttl_s, touched_at) VALUES ($id, $ttl, $at)",
                ("$id", lane), ("$ttl", ttlS), ("$at", Now()));

    /// <summary>
    /// Forget everything. Called when a fresh Chrome starts.
    ///
    /// Not a migration and not a repair: every row here names a CDP target id
    /// from a browser that is gone, and those ids are never handed out again.
    /// </summary>
    public static void Reset()
    {
        using SqliteConnection connection = Open();
        Execute(connection,
                "DROP TABLE IF EXISTS screen_claims;"
                + "DROP TABLE IF EXISTS tabs;"
                + "DROP TABLE IF EXISTS lanes;");
    }

    /// <summary>
    /// Mint a lane and return its id.
    ///
    /// Server-side rather than caller-named. A caller-chosen name saves one round
    /// trip and collides the moment two subagents of one session both pick
    /// "scratch", which is the failure this whole mechanism exists to remove.
    /// </summary>
    public static string OpenLane(int ttlS = DefaultTtlS)
    {
        string lane = Convert.ToHexString(RandomNumberGenerator.GetBytes(8)).ToLowerInvariant();
        using SqliteConnection connection = Open();
        Ensure(connection, lane, ttlS);
        return lane;
    }

    /// <summary>The lane, or LaneNotFound. Every lane-taking call starts here.</summary>
    public static Lane Require(string lane)
    {
        using SqliteConnection connection = Open();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText =
            "SELECT id, ttl_s, touched_at FROM lanes WHERE id = $id";
        command.Parameters.AddWithValue("$id", lane);
        using SqliteDataReader row = command.ExecuteReader();
        if (!row.Read())
        {
            throw new LaneNotFoundException(lane);
        }

        return new Lane
        {
            Id = row.GetString(0),
            TtlS = row.GetInt32(1),
            TouchedAt = row.GetInt64(2),
        };
    }

    /// <summary>
    /// Restart the lane's clock.
    ///
    /// Called on entry *and* on return of every call naming the lane, because a
    /// `script` with a 600s budget or a `show_browser` with a 900s wait must not
    /// expire underneath itself.
    /// </summary>
    public static void Touch(string lane)
    {
        using SqliteConnection connection = Open();
        Execute(connection, "UPDATE lanes SET touched_at = $at WHERE id = $id",
                ("$at", Now()), ("$id", lane));
    }

    /// <summary>Change how long this lane may sit quiet, and restart its clock.</summary>
    public static void SetTtl(string lane, int seconds)
    {
        Require(lane);
        using SqliteConnection connection = Open();
        Execute(connection,
                "UPDATE lanes SET ttl_s = $ttl, touched_at = $at WHERE id = $id",
                ("$ttl", Math.Max(seconds, 0)), ("$at", Now()), ("$id", lane));
    }

    /// <summary>Record that this tab belongs to this lane, moving it if it did not.</summary>
    public static void Adopt(string tab, string lane)
    {
        using SqliteConnection connection = Open();
        Execute(connection,
                "INSERT INTO tabs (tab, lane) VALUES ($tab, $lane) "
                + "ON CONFLICT(tab) DO UPDATE SET lane = excluded.lane",
                ("$tab", tab), ("$lane", lane));
    }

    public static string? Owner(string tab)
    {
        using SqliteConnection connection = Open();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "SELECT lane FROM tabs WHERE tab = $tab";
        command.Parameters.AddWithValue("$tab", tab);
        return command.ExecuteScalar() as string;
    }

    public static IReadOnlyList<string> TabsOf(string lane)
    {
        using SqliteConnection connection = Open();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "SELECT tab FROM tabs WHERE lane = $lane";
        command.Parameters.AddWithValue("$lane", lane);
        using SqliteDataReader rows = command.ExecuteReader();
        var tabs = new List<string>();
        while (rows.Read())
        {
            tabs.Add(rows.GetString(0));
        }

        return tabs;
    }

    /// <summary>Drop rows for tabs that are gone. Closing is somebody else's job.</summary>
    public static void Forget(params string[] tabs)
    {
        using SqliteConnection connection = Open();
        foreach (string tab in tabs)
        {
            Execute(connection, "DELETE FROM tabs WHERE tab = $tab", ("$tab", tab));
        }
    }

    /// <summary>
    /// Remove the lane. Its tab and claim rows cascade.
    ///
    /// The caller closes the tabs first. A lane removed while its tabs are still
    /// open would leave them with no owner, no clock and no caller who can see
    /// them -- permanently unreachable, which is worse than the pile this
    /// replaces.
    /// </summary>
    public static void Destroy(string lane)
    {
        using SqliteConnection connection = Open();
        if (lane is Cli or Orphan)
        {
            // Reserved lanes are emptied, never removed: the next call would
            // recreate them anyway, and `destroy_lane('orphan')` reading as
            // success while the lane came straight back is a lie.
            Execute(connection, "DELETE FROM tabs WHERE lane = $lane", ("$lane", lane));
            return;
        }

        Execute(connection, "DELETE FROM lanes WHERE id = $id", ("$id", lane));
    }

    public static IReadOnlyList<string> Expired(long? now = null)
    {
        long at = now ?? Now();
        using SqliteConnection connection = Open();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText =
            "SELECT id FROM lanes WHERE ttl_s != 0 AND $at - touched_at >= ttl_s";
        command.Parameters.AddWithValue("$at", at);
        using SqliteDataReader rows = command.ExecuteReader();
        var lanes = new List<string>();
        while (rows.Read())
        {
            lanes.Add(rows.GetString(0));
        }

        return lanes;
    }

    // --- the screen ---------------------------------------------------------
    //
    // Lanes divide tabs. They do not divide the compositor, the VNC server or the
    // viewer window, and `hide_browser()` used to take no arguments and dismiss the
    // presenter globally -- so lane A summoning a human for a captcha and lane B
    // calling `hide_browser` thirty seconds later took the window away mid-solve.
    // That is one lane interrupting another, which is the thing lanes are for.
    //
    // So the screen is refcounted: a claim per lane, and the viewer comes down when
    // the last one goes. It turns `hide_browser` from a global verb into "I am done
    // with it", which is what the caller means by it anyway.

    public static void ClaimScreen(string lane)
    {
        using SqliteConnection connection = Open();
        Execute(connection, "INSERT OR IGNORE INTO screen_claims (lane) VALUES ($lane)",
                ("$lane", lane));
    }

    /// <summary>Drop this lane's claim. True when nobody is left holding the screen.</summary>
    public static bool ReleaseScreen(string lane)
    {
        using SqliteConnection connection = Open();
        Execute(connection, "DELETE FROM screen_claims WHERE lane = $lane", ("$lane", lane));
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM screen_claims";
        return Convert.ToInt64(command.ExecuteScalar()) == 0;
    }

    public static IReadOnlyList<string> ScreenClaims()
    {
        using SqliteConnection connection = Open();
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "SELECT lane FROM screen_claims";
        using SqliteDataReader rows = command.ExecuteReader();
        var claims = new List<string>();
        while (rows.Read())
        {
            claims.Add(rows.GetString(0));
        }

        return claims;
    }

    // --- reconciling with Chrome --------------------------------------------

    /// <summary>
    /// Make the table agree with what Chrome actually holds.
    ///
    /// Two directions. Rows for tabs that are gone are dropped -- they are dead
    /// weight, and a stale row would make `list_tabs` promise a tab that closed.
    /// And targets with no row are attributed: to the lane of whichever tab opened
    /// them when Chrome says one did, otherwise to `orphan`.
    ///
    /// Adoption by opener is what keeps `window.open` and `target="_blank"` from
    /// leaking. Such a target has no row, so nobody can see it, nobody can close
    /// it, and the sweep never reaches it -- the sweep collects lanes, not tabs.
    /// </summary>
    public static void Reconcile(IReadOnlyList<string> live,
                                 IReadOnlyDictionary<string, string> openedBy)
    {
        using SqliteConnection connection = Open();
        var known = new Dictionary<string, string>();
        using (SqliteCommand command = connection.CreateCommand())
        {
            command.CommandText = "SELECT tab, lane FROM tabs";
            using SqliteDataReader rows = command.ExecuteReader();
            while (rows.Read())
            {
                known[rows.GetString(0)] = rows.GetString(1);
            }
        }

        var liveSet = new HashSet<string>(live);
        List<string> gone = [.. known.Keys.Where(tab => !liveSet.Contains(tab))];
        foreach (string tab in gone)
        {
            Execute(connection, "DELETE FROM tabs WHERE tab = $tab", ("$tab", tab));
            known.Remove(tab);
        }

        foreach (string tab in live)
        {
            if (known.ContainsKey(tab))
            {
                continue;
            }

            // An opener whose own row is missing means a chain of popups seen
            // out of order; `orphan` is the honest answer rather than a guess.
            string opener = openedBy.GetValueOrDefault(tab, "");
            string lane = known.GetValueOrDefault(opener, Orphan);
            Execute(connection, "INSERT INTO tabs (tab, lane) VALUES ($tab, $lane)",
                    ("$tab", tab), ("$lane", lane));
            known[tab] = lane;
        }
    }

    /// <summary>
    /// Reconcile, then collect every lane whose clock ran out. Returns which.
    ///
    /// Opportunistic: run at the top of any call that touches the registry, so
    /// there is no background thread and nothing to keep alive. Same shape as
    /// `Sessions.ReapStale`, which runs when the daemon starts for the same
    /// reason.
    ///
    /// Closing goes through the CDP HTTP endpoint rather than Patchright, so tab
    /// bookkeeping keeps working when a renderer does not -- and so that a sweep
    /// at the top of every call does not pay for an attach that initialises every
    /// open tab.
    /// </summary>
    public static IReadOnlyList<string> Sweep()
    {
        IReadOnlyList<string> live;
        try
        {
            live = [.. Targets.Pages().Select(p => p.Id)];
        }
        catch (Exception)
        {
            return [];  // no daemon, or it is not answering; nothing to reconcile
        }

        Reconcile(live, Targets.Openers());
        IReadOnlyList<string> dead = Expired();
        foreach (string lane in dead)
        {
            CloseTabs(lane, TabsOf(lane));
            Destroy(lane);
        }

        return dead;
    }

    /// <summary>
    /// Close these tabs of this lane, and forget them. Returns how many went.
    ///
    /// **The last tab is never closed.** Chrome exits when it loses its final tab,
    /// which would take the daemon and the warm session with it -- the reason the
    /// old `close_other_tabs` was phrased as "keep that one" rather than "close
    /// all". Under lanes that phrasing no longer works, because the survivor must
    /// belong to nobody in particular, so the rule becomes an invariant here
    /// instead: whatever is asked for, one page stays. It lands in `orphan` on the
    /// next reconcile, which is the correct home for a tab that exists only so
    /// Chrome keeps running.
    /// </summary>
    public static int CloseTabs(string lane, IReadOnlyList<string> tabs)
    {
        var mine = new HashSet<string>(TabsOf(lane));
        List<string> doomed = [.. tabs.Where(mine.Contains)];
        List<string> live;
        try
        {
            live = [.. Targets.Pages().Select(p => p.Id)];
        }
        catch (Exception)
        {
            return 0;
        }

        if (doomed.Count >= live.Count)
        {
            // Would empty the browser. Hold one back rather than closing it and
            // racing to open a replacement before Chrome notices.
            doomed = [.. doomed.Take(Math.Max(live.Count - 1, 0))];
        }

        int closed = 0;
        foreach (string tab in doomed)
        {
            if (Targets.Close(tab))
            {
                closed++;
            }

            Forget(tab);
        }

        return closed;
    }

    /// <summary>
    /// Total pages Chrome holds, and how many are in `orphan`.
    ///
    /// The one number that reveals a lane you do not own. A caller sees only its
    /// own tabs, so without this there is no view anywhere in the tool that shows
    /// tabs piling up -- and this map began with a stack that was silently broken
    /// while every status read healthy. A count is a measurement; ids and owners
    /// would be a listing, which is the side of the line agents stay off.
    /// </summary>
    public static (int Open, int Orphaned) Counts()
    {
        List<string> live;
        try
        {
            live = [.. Targets.Pages().Select(p => p.Id)];
        }
        catch (Exception)
        {
            return (0, 0);
        }

        var liveSet = new HashSet<string>(live);
        return (live.Count, TabsOf(Orphan).Count(liveSet.Contains));
    }
}
