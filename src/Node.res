// Node's own surface, bound thinly. Nothing here is Passenger's; it is the
// runtime the C# side got from the BCL, in the shape ReScript can call.

type vmContext
type script

@module("node:vm") external createContext: 'a => vmContext = "createContext"

// `new vm.Script`, not `SourceTextModule`. The module form carries top-level
// `await` natively but has no top-level `return`, and a caller writes
// `return`. Wrapping the source in an async IIFE gives both -- and because the
// prefix carries no newline, line 1 of the caller's source is still line 1 in
// a stack trace, which is the property ticket 023 bought for the C# door with
// a file path and emitted debug information. Measured: a throw on line 3 is
// reported as `<script>:3`.
@module("node:vm") @new
external script: (string, {"filename": string}) => script = "Script"

@send external runInContext: (script, vmContext) => promise<'a> = "runInContext"

let wrap = source => "(async()=>{" ++ source ++ "\n})()"
