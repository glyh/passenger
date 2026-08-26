// Node's own surface, bound thinly. Nothing here is Passenger's; it is the
// runtime the C# side got from the BCL, in the shape ReScript can call.

type script

// `new vm.Script`, not `SourceTextModule`. The module form carries top-level
// `await` natively but has no top-level `return`, and a caller writes
// `return`. Wrapping the source in an async arrow gives both -- and because the
// prefix carries no newline, line 1 of the caller's source is still line 1 in
// a stack trace, which is the property ticket 023 bought for the C# door with
// a file path and emitted debug information. Measured: a throw on line 3 is
// reported as `<script>:3`.
@module("node:vm") @new
external script: (string, {"filename": string}) => script = "Script"

// `runInThisContext`, not `runInContext`, since ticket 074.
//
// A `vm.createContext` context starts with V8's intrinsics and *none* of
// Node's globals, so every name a script could reach had to be put back by
// hand -- which made the bound list a confinement whether or not it was meant
// as one. This process runs on the caller's own machine, driving their own
// logged-in Chrome, so there was nothing on the other side of that wall to
// keep out. Running in this context gives a script the globals this process
// already has: `fetch`, `URL`, `Buffer`, `process`, the timers, all of it.
//
// What is still handed in by name is handed in as *arguments* instead, by
// `Script.bound` -- which is what lets `console` be shadowed rather than
// replaced. The wrapper is an expression now rather than a call, so this
// returns the function; the caller applies it.
@send external runInThisContext: script => 'a = "runInThisContext"

/// The caller's source as an async function of the names bound around it.
///
/// One line is added, and it is the closing `\n})` at the end -- `where`
/// depends on that being exactly one, and the prefix carrying no newline is
/// what keeps line 1 at line 1.
let wrap = (source, ~names) =>
  "(async(" ++ names->Array.join(",") ++ ")=>{" ++ source ++ "\n})"

@val @scope("process") external cwd: unit => string = "cwd"
