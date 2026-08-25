// node:sqlite, which ships with the runtime.
//
// The C# side took `Microsoft.Data.Sqlite` as a package; Node 22 onwards has
// this built in, so the registry costs no dependency at all.

type db
type stmt

@module("node:sqlite") @new external database: string => db = "DatabaseSync"
@send external exec: (db, string) => unit = "exec"
@send external prepare: (db, string) => stmt = "prepare"
@send external close: db => unit = "close"

@send external run: (stmt, {..}) => unit = "run"
@send external runBare: stmt => unit = "run"
@send external all: (stmt, {..}) => array<'row> = "all"
@send external allBare: stmt => array<'row> = "all"
