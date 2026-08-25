// The handful of POSIX calls the runtime does not otherwise expose.
//
// The C# side had to reach libc through DllImport for these: `Process.Kill`
// sends SIGKILL and only to a process it can open a handle to, which is not the
// same act as SIGTERM to a recorded pid that may already be gone. Node gives
// both directly -- `process.kill` takes the signal by name and works on any pid
// -- so what was a P/Invoke there is a one-line binding here.
//
// Signalling a pid this tool did not start is load-bearing (session teardown,
// dismissing the viewer), and escalating SIGTERM to SIGKILL is the fix ticket
// 024 landed, so the distinction cannot be given up.

@val @scope("process") external killRaw: (int, string) => unit = "kill"

let sigterm = "SIGTERM"
let sigkill = "SIGKILL"

/// Signal one process, tolerating its having already gone.
///
/// Both failures the Python side caught -- ProcessLookupError and
/// PermissionError -- are swallowed the same way, because both mean this tool is
/// not going to be the one that stops that process.
let kill = (pid, signal) =>
  switch killRaw(pid, signal) {
  | () => ()
  | exception _ => ()
  }
