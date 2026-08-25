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
let number = text => {
  let digits = ref("")
  let done = ref(false)
  text
  ->String.trim
  ->String.split("")
  ->Array.forEach(ch => {
    if !done.contents {
      let isDigit = ch >= "0" && ch <= "9"
      let firstDot = ch == "." && !(digits.contents->String.includes("."))
      if isDigit || firstDot {
        digits := digits.contents ++ ch
      } else if digits.contents->String.length > 0 {
        done := true
      }
    }
  })

  // C# reached `double.Parse` here and would have thrown on a lone ".", which
  // no recorded output has produced but nothing prevented either. Float.fromString
  // answers None for it, so the parser has one fewer way to take the session down.
  digits.contents == "" ? None : Float.fromString(digits.contents)
}

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
