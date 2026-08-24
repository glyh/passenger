---
id: 053
title: Delete the Python door
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

023 built the C# port beside the Python original and named the condition for
deleting Python: "a couple of weeks of daily use rather than a green test
run." That measurement was never taken -- this ticket deletes it anyway, on
the owner's direct instruction rather than on 023's own bar. Recorded here so
the gap is visible rather than quietly stepped over.

## What went

`passenger/` (the Python package), `tests/` (its suite), `pyproject.toml`, and
the three Python-only Nix derivations (`nix/mcp-types.nix`,
`nix/python-overlay.nix`, `nix/patchright.nix`) -- `nix/` itself with them,
empty once those three were gone. `skills/using-passenger` (the Python-verb
skill) went too, and `skills/using-passenger-csharp` was renamed to
`skills/using-passenger`, the Python skill's old address: there is one door now, so the
discriminator both skills carried -- "the C# door", "the Python door", a
**Which door you are at** section in each -- was dead weight, and 049's own
premise (two skills to avoid drift between them) no longer holds with one.

`dotnet/` was a language namespace next to `passenger/`, the Python package it
sat beside; with only one language left it was the thing casting a shadow with
nothing to distinguish itself from, so `dotnet/src`, `dotnet/tests`,
`dotnet/Passenger.slnx`, `dotnet/Directory.Build.props` and the fetched
`dotnet/deps.json` all moved up to the repository root. `flake.nix`'s
`projectFile` paths and the README's layout table moved with them; no `.cs`
file names `dotnet/` itself, so nothing inside the solution needed to change.

This closes [050](050-csharp-door-names-the-python-skill.md) by construction
rather than by the find-and-replace it proposed: the server's four strings
already said `using-passenger` (050's finding was that they were pointing at
the *wrong* file, not the wrong name), and renaming the surviving skill to
that address makes them correct without touching `Program.cs` or `Tools.cs`
at all.

## Two bugs the deletion surfaced

**The walker recipe pasted a file it could have read.** The C# skill told an
agent to copy `walker.js`'s contents into a raw string literal -- which is
exactly the transcription [052](052-walker-escapes-do-not-survive-transport.md)
documents as hazardous, since the walker's regex carries a pair of
backslash-`u` escapes that decode to real line terminators crossing a JSON
tool-call boundary. The server runs on the caller's own machine (confirmed
fact, not assumption: 050's own skill eval had every agent independently bet
that a script's `File.*` calls land on the local disk, and it does) -- so the
recipe now reads `walker.js` from its path with `File.ReadAllTextAsync`
instead of pasting it, which makes 052's whole failure mode unreachable rather
than merely documented. The skill also gained a standing sentence near the
top -- the server is local, in your filesystem, in both directions -- since
that was a fact three convergent findings in 050 wanted and neither skill
stated.

**`SessionTests.cs` assumed `/bin/sleep`.** Building the flake's package with
`doCheck = true` for the first time ran the suite somewhere that assumption is
false -- a Nix build sandbox has no FHS `/bin` -- and four tests failed on
`No such file or directory`. Fixed by starting `"sleep"` unqualified and
letting `Process.Start` resolve it off `PATH`, which coreutils occupies
everywhere this runs, sandbox included. Nobody had run the suite in a context
where the bug was visible before -- the Python suite's equivalent (ticket 001)
already took the same care, spawning `true` and `sleep` unqualified for the
same reason.

## The flake, packaged for the first time

023 left "the flake does not build it" on the C# side as owed work. It has one
now: `buildDotnetModule`, a locked `deps.json` (regenerate with
`nix build .#default.passthru.fetch-deps`), both `Passenger.Cli` and
`Passenger.Mcp` published into one directory and wrapped with the same
`runtimeDeps` (cage, wayvnc, wlr-randr, wayland-utils) and `PASSENGER_NOVNC`
the Python package's wrapper carried. `nix run .#mcp` and `nix run .` both
work; `nix flake check` runs the whole `Passenger.Tests` suite as part of the
build rather than a separate `checks` output, since -- unlike the Python
suite's one browser-dependent test -- nothing in it drives a real Chrome, so
there is no pinned-chromium reason to keep it apart.

One patch was needed to make the package build at all: the `Patchright`
NuGet package bundles its own Node to drive Playwright's wire protocol, linked
against `/lib64/ld-linux-x86-64.so.2`, which does not exist in the store. Same
shape of problem the deleted `nix/patchright.nix` solved for the Python
dependency of the same name, and the same fix: `postFixup` replaces the
bundled binary with a symlink to nixpkgs' own `node` rather than patching the
ELF interpreter.

The live MCP registration changed with it: `passenger` (Python,
`python -m passenger.mcp_server`) and `passenger-csharp` (a hand-published
`dotnet/publish/mcp/Passenger.Mcp` binary) are both gone from the user's
`claude mcp` config, replaced by one `passenger` pointing at
`nix run /path/to/passenger#mcp` -- the reproducible build, not the manual one.

## Not done

The measurement 023 named -- daily use, not a green suite -- never happened.
If the C# port has a latent defect the Python original did not, deleting the
fallback removed the option to notice by comparison. Nothing here found one;
nothing here was built to look.
