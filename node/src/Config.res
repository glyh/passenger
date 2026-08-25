// Every PASSENGER_* variable is read exactly once, here.
//
// A `ref` rather than a constant for the same reason `Config.Settings` has a
// setter on the C# side: the test suite points the state directory at a temp
// path before anything opens the registry, so a suite never writes a
// developer's real `lanes.db`.

@val @scope("process") external env: Dict.t<string> = "env"

let raw = name => env->Dict.get(name)

@module("node:os") external homedir: unit => string = "homedir"
@module("node:path") external join: (string, string, string, string) => string = "join"

let stateDir = ref(
  switch raw("PASSENGER_STATE") {
  | Some(dir) => dir
  | None => join(homedir(), ".local", "share", "passenger")
  },
)
