// Starting other programs, bound thinly.
//
// Three shapes are needed and they are genuinely different acts, so they are
// three bindings rather than one with flags:
//
//   run       a tool that answers on stdout and exits (wlr-randr, wayland-info)
//   spawn     a long-lived child this process keeps a handle on
//   detach    a child that must outlive this process -- sway, and the viewer's
//             server. `detached` plus `unref` is what `start_new_session=True`
//             was on the Python side; .NET needed neither because a child of a
//             UseShellExecute=false start already survives its parent.
//
// Every environment here is layered over the current one rather than replacing
// it: passing a bare dictionary drops PATH, and the command then cannot be found
// even though it is installed. That was a real bug on the C# side and the
// comment there says so.

type child
type result

@module("node:child_process") external spawnRaw: (string, array<string>, {..}) => child = "spawn"
@module("node:child_process")
external spawnSyncRaw: (string, array<string>, {..}) => result = "spawnSync"

@get external stdoutOf: result => Nullable.t<string> = "stdout"
@get external statusOf: result => Nullable.t<int> = "status"
@get external pidOf: child => Nullable.t<int> = "pid"
@send external unref: child => unit = "unref"
@send external killChild: (child, string) => unit = "kill"

@val @scope("process") external env: Dict.t<string> = "env"

/// The current environment with these entries laid over it.
let withEnv = extra => {
  let merged = Dict.make()
  env->Dict.forEachWithKey((value, key) => merged->Dict.set(key, value))
  extra->Dict.forEachWithKey((value, key) => merged->Dict.set(key, value))
  merged
}

/// Run a tool and return its stdout, or "" if it could not run at all.
///
/// Failures are swallowed because every caller is improving the picture, never
/// keeping the session alive -- a missing tool should cost sharpness, not the
/// browser.
let run = (~env as extra=?, command, args) =>
  switch spawnSyncRaw(
    command,
    args,
    {
      "encoding": "utf8",
      "env": switch extra {
      | Some(e) => withEnv(e)
      | None => env
      },
    },
  ) {
  | result => result->stdoutOf->Nullable.toOption->Option.getOr("")
  | exception _ => ""
  }

/// Run a tool for its exit status alone. `None` if it could not run.
let status = (~env as extra=?, command, args) =>
  switch spawnSyncRaw(
    command,
    args,
    {
      "encoding": "utf8",
      "env": switch extra {
      | Some(e) => withEnv(e)
      | None => env
      },
    },
  ) {
  | result => result->statusOf->Nullable.toOption
  | exception _ => None
  }

/// Start a child that must outlive this process, and return its pid.
///
/// stdio to /dev/null throughout, which is what keeps it from holding this
/// process's own streams open -- and that matters here more than it did on the
/// C# side, because stdout is the JSON-RPC transport.
let detach = (~env as extra=?, command, args) =>
  switch spawnRaw(
    command,
    args,
    {
      "detached": true,
      "stdio": "ignore",
      "env": switch extra {
      | Some(e) => withEnv(e)
      | None => env
      },
    },
  ) {
  | child =>
    child->unref
    child->pidOf->Nullable.toOption
  | exception _ => None
  }
