// Every boundary shape, as records the compiler will not let you build wrong.

type kind = Challenge | Login | Unknown

// What a signature tests. The C# side had three nullable fields -- TitleRe,
// UrlRe, Selector -- and a `Validated()` that threw when all three were null,
// because a condition-less signature matches nothing, silently. `Models.cs`
// says that invariant came from pydantic's model_validator and was kept by
// hand; `DetectTests.cs` spent a test holding it.
//
// Here it is neither: a signature carries one condition plus any others, so a
// signature with no condition cannot be written down. That is the same move
// ticket 021 made when it took `word_count` off PageProbe and the comment in
// `DetectTests.cs` records -- "structural rather than tested".
type condition =
  | Title(string)
  | Url(string)
  | Selector(string)

type signature = {
  name: string,
  kind: kind,
  first: condition,
  rest: array<condition>,
}

let conditions = s => [s.first]->Array.concat(s.rest)

/// What the shell measured, and all `Detect` is allowed to see.
type probe = {
  url: string,
  title: string,
  matchedSelectors: array<string>,
}

type blocker = {
  signature: signature,
  probe: probe,
}
