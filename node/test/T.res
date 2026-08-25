// node:test, bound to the three things a pure test needs.
@module("node:test") external test: (string, unit => unit) => unit = "test"
@module("node:assert/strict") external equal: ('a, 'a) => unit = "equal"
@module("node:assert/strict") external ok: bool => unit = "ok"
