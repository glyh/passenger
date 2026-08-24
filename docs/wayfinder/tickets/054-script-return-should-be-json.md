---
id: 054
title: script's return value should be JSON, not another wrapping layer
labels: [wayfinder:task]
status: closed
assignee: lyh (via Claude)
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

## Answer

*Closed undone, 2026-08-24. The shape is what it should be; nothing was built.*

Settled by looking at real replies through the MCP door rather than reasoning
about the record. Two calls, one returning an object and one returning the
markdown a page read produces:

    {"type":"ran","tab":"DB3D…","returned":{"title":"Example Domain","count":3},
     "page":{…}}

    {"type":"ran","tab":"12AD…",
     "returned":"# Example Domain\nThis domain is for use in documentation…",
     "page":{…}}

That is the shape the ticket describes, and on inspection it is the wanted one.
Option 3 stands as written: `returned` is a clearly named slot for whatever the
script said, and it is worth the one hop.

What the second reply shows is the sharper version of the complaint, and it is
not the one the ticket names. A page read arrives JSON-escaped onto a single
line, `\n` for every break, and the whole page lands in the caller's context
whether it wanted all of it or not. **Fusing named fields would not have touched
that**: a string has no fields to fuse, and reading a page is the case that
hurts.

That has a remedy, and it costs nothing at either door, because the answer was
already in the skill under a different heading -- *the server runs on your
machine, in your filesystem*. The recipe writes the markdown out and returns
where it put it:

    var markdown = await Page.EvaluateAsync<string>(walker);
    var path = "/tmp/pep8.md";              // the caller's to name
    await File.WriteAllTextAsync(path, markdown);
    return new Dictionary<string, object> { ["path"] = path, ["chars"] = markdown.Length };

Measured on `https://peps.python.org/pep-0008/` through the MCP door: 45,389
characters delivered in a reply of about 250 bytes, and on disk as 1,061 real
lines rather than one escaped one. `chars` rides along so the caller still has a
number to read against expectation.

Note where the change had to go. `walker.js` runs *inside the page*, which has
no filesystem, so it cannot write the file itself -- the write belongs to the
C# around it, and this is a change to the recipe in `SKILL.md` rather than to
any code at either door. Shipped there.

So `returned` keeps its slot and its name, and the escaping stops being the
common case rather than being argued about.

### A correction to the Question

It names `lookAt` as one of the tools returning its own shape directly. There is
no such tool. The ten are `script`, `openLane`, `setTtl`, `listTabs`,
`closeTabs`, `closeAllTabs`, `destroyLane`, `showBrowser`, `hideBrowser` and
`browserStatus`. The point it was making holds for the nine that are real.

### What 055 changed underneath it

[055](055-envelope-goes-the-caller-measures.md) landed while this was open and
deleted the `measured` variant, so the envelope beside `returned` is now `type`,
`tab` and a `page` that is a wall or `unchecked`. That shrinks option 1's
collision surface to three names, and it shrinks the amount there is to reach
past -- both of which make leaving it alone easier, not harder.
