// Node's filesystem and process surface, bound thinly. Nothing here is
// Passenger's; it is what the C# side got from the BCL.
//
// Synchronous throughout, deliberately. Every caller is either start-up or a
// /proc read that is a syscall away from returning, and the async forms would
// turn a pure predicate like "is this pid alive" into a promise that then has to
// travel through every rule that asks it -- which is the one signature change
// this port has already paid for once, in `Lanes.chromeTabs`.

type stats
type dirent

@module("node:fs") external readFileSync: (string, string) => string = "readFileSync"
@module("node:fs") external readFileBytes: string => Uint8Array.t = "readFileSync"
@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("node:fs") external existsSync: string => bool = "existsSync"
@module("node:fs") external readdirSync: string => array<string> = "readdirSync"
@module("node:fs") external unlinkSync: string => unit = "unlinkSync"
@module("node:fs") external chmodSync: (string, int) => unit = "chmodSync"
@module("node:fs") external readlinkSync: string => string = "readlinkSync"
@module("node:fs") external statSync: string => stats = "statSync"
@get external mode: stats => int = "mode"

type mkdirOptions = {recursive: bool}
@module("node:fs") external mkdirSync: (string, mkdirOptions) => unit = "mkdirSync"

@module("node:path") external join: (string, string) => string = "join"
@module("node:path") external resolve: string => string = "resolve"
@module("node:path") external extname: string => string = "extname"
@module("node:path") external dirname: string => string = "dirname"

/// The error code a failed syscall carries -- "ENOENT", "EACCES" and the rest.
/// `None` when whatever was thrown was not one of Node's system errors.
@get external errorCode: JsExn.t => option<string> = "code"

/// Read a text file, or nothing. The distinction between "not there" and
/// "unreadable" is the caller's when it matters; most of the time it does not.
let readText = path =>
  switch readFileSync(path, "utf8") {
  | text => Some(text)
  | exception _ => None
  }

let mkdirp = path =>
  switch mkdirSync(path, {recursive: true}) {
  | () => ()
  | exception _ => ()
  }

/// Unlink, tolerating a path that was never there.
let delete = path =>
  switch unlinkSync(path) {
  | () => ()
  | exception _ => ()
  }
