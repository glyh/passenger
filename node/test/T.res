// node:test, bound to the three things a pure test needs.
//
// `equal` is `deepStrictEqual`, not `strictEqual`: ReScript arrays, tuples and
// records are JS objects, so reference equality would pass only when a test
// compared a value to itself. Thirteen ported Lanes cases failed on exactly
// that before this line said `deepEqual`.
@module("node:test") external test: (string, unit => unit) => unit = "test"
@module("node:assert/strict") external equal: ('a, 'a) => unit = "deepEqual"
@module("node:assert/strict") external ok: bool => unit = "ok"
