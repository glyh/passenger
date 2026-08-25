// The files that ship beside the code, and how to read one.
//
// Everything here is a template or a page rather than code: the viewer a human
// takes the browser over in, and the session's own shell script, sway config and
// IME snippet. They are *files* rather than string literals so a shell script can
// be read, diffed and linted as one -- which is the C# side's reasoning, kept.
//
// What changes is how they are found. There they were embedded resources, so a
// single-file publish still carried them; here they sit next to the compiled
// modules and are read relative to this file. `import.meta.dirname` rather than
// the process's working directory, which is the client's and not ours.
//
// **These are the same four files as `src/Passenger/Assets/`, copied.** That is
// a duplication with a shelf life: it ends when the C# tree does. Until then a
// test compares the two, so an edit to one that misses the other fails rather
// than quietly shipping a session script and a sway config that disagree.

@val @scope("import.meta") external dirname: string = "dirname"

let root = () => Fs.join(Fs.join(dirname, ".."), "assets")

/// An asset, by its path under `assets/`.
///
/// Missing is a packaging error that got as far as running, not a condition any
/// caller can do anything about, so it throws rather than answering `None`.
let read = name =>
  switch Fs.readText(Fs.join(root(), name)) {
  | Some(text) => text
  | None => throw(Failure(`${name} is missing from the assets directory`))
  }
