---
id: 072
title: Getting a file into the session, since a drag cannot
labels: [wayfinder:task]
status: open
assignee:
blocked_by: []
---

## Question

Dragging a file from the host desktop onto the viewer does nothing. Found by
hand, during the first handoff driven through the node port: everything else
worked -- paste in, copy out, in-page HTML5 drag and drop between elements --
and the file drop was silent.

**This is not a bug and cannot be fixed where it was looked for.** RFB carries
pointer, keyboard, framebuffer and clipboard. It has no file transfer, so the
drag never leaves the host machine: the drop lands on the *viewer* page, which
is an ordinary browser window on the host, and the nested browser is never
told anything happened.

`Assets/web/viewer.html` already knew, and the comment there is the whole
finding:

    // A file dropped on this page is a file dropped on an ordinary browser, and
    // a browser's default for that is to navigate to it -- so dragging a log
    // file onto the viewer opened it in a *host* window, having done nothing
    // remote at all. RFB carries no file transfer and this is not the place to
    // invent one: the session shares this filesystem, so its own file chooser
    // already reaches any path on it.

So the viewer's `preventDefault` is why the drag is *silent* rather than why it
fails -- without it, the failure was louder and worse. What this ticket is for
is the half that comment leaves implicit: a caller reading the skill has no way
to know any of this, and the answer it points at is not the only one, or the
best one for an agent.

### It is upstream's position too, not a packaging gap

noVNC 1.7.0 ships no drag-and-drop path at all: `dataTransfer`, `dragover` and
`drop` appear nowhere in the tree, where `clipboard` is right there in
`core/rfb.js`. The request is [issue 169][169], open since **June 2012**, in
the "Future Features" milestone with "patches welcome" and no maintainer
committing to it; it has been re-asked at least four more times since
([790][790], [702][702], [1060][1060], [1869][1869]). Nothing to wait for and
nothing to configure.

[169]: https://github.com/novnc/noVNC/issues/169
[790]: https://github.com/novnc/noVNC/issues/790
[702]: https://github.com/novnc/noVNC/issues/702
[1060]: https://github.com/novnc/noVNC/issues/1060
[1869]: https://github.com/novnc/noVNC/issues/1869

### And the fix would buy nothing here anyway

Worth stating, because it is what makes this a documentation task rather than a
feature request to carry. Suppose noVNC grew TightVNC-style transfer tomorrow.
It would move bytes to the far side's filesystem -- and **the far side's
filesystem is this one**. `Launch.NestedBackend` starts sway on the host, so
Chrome in that session sees the same paths under the same uid; the session
script even symlinks the host's `$XDG_CONFIG_HOME` into it. The file is already
there. What is missing is not transport but a *gesture*, and a transfer
protocol does not supply one either: a file that arrives on disk does not
produce a `DataTransfer` in the page.

### What the two real answers are

Both exist today and neither is written down anywhere a caller looks.

1. **For an agent: `setInputFiles`, and no human at all.** Playwright runs on
   the host, against a browser that shares its filesystem, so it can hand a
   local path straight to a file input:

       await Page.locator('input[type=file]').setInputFiles('/tmp/x.pdf');

   That is in the bundled `playwright-core` (also `page.on('filechooser')` for
   inputs a site opens itself). No viewer, no handoff, no human -- which makes
   it strictly better than the drag for the case the drag was being tried for.
   For a site that accepts *only* a drop and has no input element, the standard
   recipe is to build a `DataTransfer` in the page and dispatch the drag events
   onto the target, which `script` can do because `script` is raw JavaScript in
   the page.

2. **For a human mid-handoff: the session's own file chooser.** Which is what
   the viewer comment says, and it works -- confirmed by hand alongside this
   finding. The cost is that the person has to type or navigate to a path
   rather than drag, and nothing tells them that is the move.

### What to do

- Say it in `skills/using-passenger/`. This is exactly the class of thing
  `CLAUDE.md` puts there rather than in a docstring: what the tool does not
  catch, and what to do instead. `references/` is the place -- a caller
  reaching for a file upload should find `setInputFiles` before it finds a
  handoff, and a caller *in* a handoff should be told to use the file chooser
  rather than dragging.
- Consider one line in the `showBrowser` description, and no more than one.
  The rule is that operating knowledge lives in the skill; the argument for an
  exception is that this is the one moment a human is looking at the window and
  about to try the gesture that cannot work. Probably still a skill matter.
- Nothing in `src/`. There is no code change that makes a drag work, and
  inventing a file-transfer channel beside RFB would be a second door onto the
  session for something `script` already does better.

### What was checked

- noVNC 1.7.0 as packaged (`PASSENGER_NOVNC`): no `dataTransfer`/`dragover`/
  `drop` anywhere; `clipboard` present in `core/rfb.js`.
- Upstream issue 169, open since 2012, plus four duplicates.
- `playwright-core` 1.62.1 types: `locator.setInputFiles` and the
  `filechooser` event both present.
- By hand through the node door: paste in, copy out and in-page drag all work;
  the file drop is silent; the session's own file chooser reaches host paths.
