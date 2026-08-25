// At what density the nested browser renders -- the pure half of it.
//
// The *size* of the nested output is not decided here and has not been since
// the viewer started asking for it over RFB. What a viewer cannot ask for is
// the *scale*, and scale is not cosmetic (tickets 002/003): it decides whether
// the nested Chrome treats a 1422x1730 output as that many CSS pixels of
// unreadably small page, or as 889x1081 at dpr 2 -- which is what an ordinary
// laptop reports, and what someone reading a captcha needs.
//
// Only the two parsers and the scale itself are here. Everything that spawns
// `wlr-randr` or `wayland-info` and applies the result is shell and ports with
// the rest of the shell; these two read fields out of human-facing output and
// are the whole of how a scale is discovered.

module Scale: {
  type t
  /// The bound pydantic held with `Field(gt=0)`, and C# kept by throwing from
  /// `Validated()`. Here the type is abstract and this is the only way in, so
  /// an unrenderable scale is not a value that exists rather than one that
  /// throws when checked.
  let make: float => option<t>
  let factor: t => float
} = {
  type t = float
  let make = f => f > 0.0 ? Some(f) : None
  let factor = t => t
}

/// Leading number of a field like `1.601562` or `2,`.
///
/// This was a character loop with two `ref` cells -- a transliteration of C#'s
/// `foreach (char ch in text.Trim())`, accumulating digits and stopping at the
/// first non-digit after them. A regex says the same thing and the equivalence
/// is what the nine cases in `Geometry_test.res` check, ported from the same
/// oracle: the first run of digits with at most one dot inside it, anywhere in
/// the string.
///
/// C# reached `double.Parse` on what it collected and would have thrown on a
/// lone ".", which no recorded output has produced but nothing prevented
/// either. There is no match to parse here, so the parser has one fewer way to
/// take the session down.
let number = text =>
  text
  ->String.match(%re("/\d+(?:\.\d+)?/"))
  ->Option.flatMap(m => m->Array.get(0)->Option.getOr(None))
  ->Option.flatMap(digits => Float.fromString(digits))

/// The first `wl_output` stanza, from its header to the next interface.
///
/// Scoped to one output because a second monitor further down the dump
/// describes a screen the viewer is not on, and returning everything would let
/// the next `scale:` on any interface be read as the screen's.
let firstBlock = report => {
  let lines = report->String.split("\n")
  switch lines->Array.findIndexOpt(l => l->String.includes("wl_output")) {
  | None => ""
  | Some(start) =>
    let after = lines->Array.slice(~start=start + 1, ~end=lines->Array.length)
    let end = switch after->Array.findIndexOpt(l => l->String.startsWith("interface:")) {
    | Some(i) => start + 1 + i
    | None => lines->Array.length
    }
    lines->Array.slice(~start, ~end)->Array.join("\n")
  }
}

// --- the shell half ---------------------------------------------------------
//
// Setting the scale leaves the framebuffer size alone, so unlike the old fitting
// it cannot disturb a connected viewer; a live session was watched through a
// scale change and back to confirm it.

let headlessPrefix = "HEADLESS"

/// An explicit scale from the environment, which wins over the probe.
let configured = () => Config.vncScale.contents->Option.flatMap(Scale.make)

/// The first output's integer buffer scale, from core `wl_output`.
let wlOutputScale = () =>
  switch Launch.which("wayland-info") {
  | None => None
  | Some(_) =>
    let found = ref(None)
    firstBlock(Proc.run("wayland-info", []))
    ->String.split("\n")
    ->Array.forEach(line =>
      // Not `startsWith`: scale shares a line with the position, as
      // `x: 0, y: 0, scale: 2,`.
      if found.contents->Option.isNone && line->String.includes("scale:") {
        found :=
          line
          ->String.split("scale:")
          ->Array.get(1)
          ->Option.flatMap(number)
          ->Option.flatMap(Scale.make)
      }
    )
    found.contents
  }

/// The scale the host screen runs, which the viewer's window inherits.
///
/// wlr-randr first and core `wl_output` second, because the two answer with
/// different precision: wl_output carries an integer buffer scale, so a screen at
/// 1.6 reads as 2, while wlr-randr reports the compositor's real fractional
/// value. The integer is a usable fallback -- Chrome rounds the scale up to an
/// integer anyway -- but it is not the same picture.
let host = () => {
  let found = ref(None)
  Proc.run("wlr-randr", [])
  ->String.split("\n")
  ->Array.forEach(line =>
    if found.contents->Option.isNone && line->String.trimStart->String.startsWith("Scale:") {
      found :=
        line->String.split("Scale:")->Array.get(1)->Option.flatMap(number)->Option.flatMap(Scale.make)
    }
  )
  switch found.contents {
  | Some(scale) => Some(scale)
  | None => wlOutputScale()
  }
}

/// The configured scale, or the host screen's, or nothing to say.
let select = () =>
  switch configured() {
  | Some(scale) => Some(scale)
  | None => host()
  }

let sessionEnv = display =>
  Dict.fromArray([("WAYLAND_DISPLAY", display), ("XDG_RUNTIME_DIR", Config.runtimeDir())])

let outputName = env => {
  let found = ref(None)
  Proc.run(~env, "wlr-randr", [])
  ->String.split("\n")
  ->Array.forEach(line =>
    if found.contents->Option.isNone && line->String.startsWith(headlessPrefix) {
      found := line->String.split(" ")->Array.filter(w => w != "")->Array.get(0)
    }
  )
  found.contents
}

/// Set the nested output's scale, or `None` if it could not be set.
///
/// Best effort by design: a failure here costs picture quality, never the
/// session, so it is reported rather than raised. Reported honestly, though --
/// announcing a scale wlr-randr refused would be the same silent lie the old
/// resize told.
let apply = (display, scale) =>
  switch Launch.which("wlr-randr") {
  | None => None
  | Some(_) =>
    let env = sessionEnv(display)
    switch outputName(env) {
    | None => None
    | Some(name) =>
      let factor = Scale.factor(scale)->Float.toString
      switch Proc.status(~env, "wlr-randr", ["--output", name, "--scale", factor]) {
      | Some(0) => Some(`scale ${factor}`)
      | _ => None
      }
    }
  }

/// Give the nested output the density of the screen it will be seen on.
let fit = display => select()->Option.flatMap(scale => apply(display, scale))
