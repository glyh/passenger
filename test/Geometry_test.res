// Reading a scale out of two tools' output. Pure: recorded text, nothing spawned.
//
// The oracle was `tests/Passenger.Tests/GeometryTests.cs`. Its ten cases are
// here except two that no longer describe anything: `AConfiguredScaleWinsOver
// TheProbe` and `NoConfiguredScaleMeansAskTheHost` read `Config.Settings`,
// which is shell and has not been ported. `AScaleOfZeroCannotExist` survives
// but changes shape -- `Scale.make` answers `None` rather than throwing,
// because the type is abstract and there is no other way to build one.

T.test("a fractional scale is read whole", () => {
  T.equal(Geometry.number(" 1.601562"), Some(1.601562))
})

T.test("a trailing comma is not part of the number", () => {
  // wayland-info writes `x: 0, y: 0, scale: 2,` -- mid-line, comma-terminated.
  T.equal(Geometry.number(" 2,"), Some(2.0))
})

T.test("only the first number is taken", () => {
  T.equal(Geometry.number("1.5 (2.0 preferred)"), Some(1.5))
})

T.test("a second dot ends the number rather than corrupting it", () => {
  // A version-like string must not parse as a nonsense float.
  T.equal(Geometry.number("1.6.2"), Some(1.6))
})

T.test("a field with no number is nothing to say", () => {
  T.equal(Geometry.number("  auto"), None)
})

T.test("a lone dot is nothing to say, where C# would have thrown", () => {
  T.equal(Geometry.number(" . "), None)
})

T.test("only the first output is read", () => {
  let report = `interface: 'wl_output', version: 4, name: 12
    x: 0, y: 0, scale: 2,
    make: 'Acme'
interface: 'wl_seat', version: 9, name: 13
    x: 0, y: 0, scale: 3,`
  let first = Geometry.firstBlock(report)
  T.ok(first->String.includes("scale: 2,"))
  T.ok(!(first->String.includes("scale: 3,")))
})

T.test("a dump with no output is empty rather than the whole thing", () => {
  T.equal(Geometry.firstBlock("interface: 'wl_seat', version: 9"), "")
})

T.test("a scale of zero cannot exist", () => {
  // The bound pydantic held with `Field(gt=0)`: a zero or negative scale is not
  // a smaller picture, it is an unrenderable one.
  T.equal(Geometry.Scale.make(0.0)->Option.isNone, true)
  T.equal(Geometry.Scale.make(-1.0)->Option.isNone, true)
  T.equal(Geometry.Scale.make(1.25)->Option.map(Geometry.Scale.factor), Some(1.25))
})
