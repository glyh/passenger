// Argument parsing, on `node:util.parseArgs`.
//
// **Why not a CLI library.** There is no ReScript-native one worth adopting --
// checked 2026-08-26, the package index has none -- so the choice was between
// binding a JavaScript one (commander, cac, yargs) and using what the runtime
// already ships. `parseArgs` has been stable since Node 20 and does the two
// things this surface needs: it separates positionals from options, and it
// refuses an option nobody declared instead of ignoring it. Help text for two
// subcommands is a string, not a feature worth a dependency -- which is the same
// call `node:sqlite` and the global `WebSocket` got, and the reason this server
// has three runtime dependencies rather than a screenful.
//
// If a third subcommand ever arrives with flags of its own, revisit it; the
// binding below is the whole of what would have to change.

type parsed = {positionals: array<string>, values: Dict.t<bool>}

@module("node:util") external parseArgsRaw: {..} => parsed = "parseArgs"

type option_ = {name: string, description: string}

/// One subcommand, and everything the usage text needs to describe it.
type command = {
  name: string,
  summary: string,
  options: array<option_>,
}

let commands = [
  {
    name: "serve",
    summary: "speak MCP over stdio -- what a client launches",
    options: [],
  },
  {
    name: "stop",
    summary: "stop chrome, losing the warm logged-in session",
    options: [
      {
        name: "force",
        description: "stop even while a lane holds tabs or the screen",
      },
    ],
  },
]

let usage = () => {
  let lines = ["usage: passenger <command> [options]", ""]
  commands->Array.forEach(c => {
    lines->Array.push(`  ${c.name->String.padEnd(6, " ")}  ${c.summary}`)
    c.options->Array.forEach(o =>
      lines->Array.push(`          --${o.name->String.padEnd(8, " ")}${o.description}`)
    )
  })
  lines->Array.join("\n")
}

/// What the argv said, or nothing if it did not say a command this knows.
///
/// `strict` is on, so an option no command declared is a parse failure rather
/// than something silently dropped -- and a typo'd `--forse` must not read as
/// "no, do not force".
type invocation = {command: command, flags: Dict.t<bool>}

let parse = argv =>
  switch argv->Array.get(0) {
  | None => None
  | Some(word) =>
    switch commands->Array.find(c => c.name == word) {
    | None => None
    | Some(command) =>
      let options = Dict.make()
      command.options->Array.forEach(o =>
        options->Dict.set(o.name, {"type": "boolean"}->Obj.magic)
      )
      switch parseArgsRaw({
        "args": argv->Array.slice(~start=1, ~end=argv->Array.length),
        "options": options,
        "strict": true,
        "allowPositionals": false,
      }) {
      | parsed => Some({command, flags: parsed.values})
      | exception _ => None
      }
    }
  }

let flag = (invocation, name) => invocation.flags->Dict.get(name)->Option.getOr(false)
