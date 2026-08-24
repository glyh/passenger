---
id: 054
title: script's return value should be JSON, not another wrapping layer
labels: [wayfinder:task]
status: open
assignee:
blocked_by: []
---

## Question

`Script`'s tool description already tells the caller "it must be JSON" for
whatever a script returns, and `Script.cs`'s `NotJson` check enforces that:
anything a script hands back that `JsonSerializer` can't round-trip is
rejected before it reaches the caller. So the value itself is JSON. What
happens next is not: `Service.RunAsync` (`Service.cs:178-187`) puts it under
`Returned` on `Ran`, which serializes as a `returned` field sitting beside
`tab` and `page`:

    { "type": "ran", "tab": "...", "returned": { ...whatever the script gave back... }, "page": { ... } }

That is a second layer of wrapping on top of the one the script author
already did to satisfy the JSON-only rule. If a script fetches an object with
fields a caller wants alongside `tab`/`page` -- or wants merged into a larger
MCP result -- it has to reach through `returned` first rather than finding
those fields at the top level. Every other tool in `Tools.cs` (`status`,
`lookAt`, `listTabs`, ...) returns its own shape directly; `script` is the one
tool whose result carries an extra hop to get at the thing the caller
actually asked for.

Worth deciding here:

1. Fuse `Returned`'s own top-level JSON object fields into `Ran` directly, so
   a script returning `{"title": ..., "count": ...}` produces
   `{"type": "ran", "tab": ..., "title": ..., "count": ..., "page": ...}` with
   no `returned` key at all. Needs an answer for what happens when the
   script's return isn't an object (a bare string, number, array, or `null`)
   -- those can't fuse into named fields the same way.
2. Keep `returned` as the field name but stop treating it as a nested
   sub-object when the script hands back an object -- i.e. spread only in the
   object case, keep the wrapper for scalars/arrays. Less uniform, but avoids
   inventing behavior for shapes that don't fuse.
3. Leave it wrapped and treat this as intentional: `returned` is a clearly
   named slot for "whatever the script said," and merging it into the parent
   risks colliding with `tab`/`page`/`type` if a script's object happens to
   use those names. The trade this ticket is weighing is caller convenience
   against that collision risk.

Whatever is chosen, `Ran`'s doc comment and the `script` tool's
`[Description]` in `Tools.cs` should say plainly what shape a script's return
value ends up in, since right now the description promises JSON but not
where in the result it lands.
