---
id: 065
title: The viewer answers from whichever build got the port first
labels: [wayfinder:task]
status: open
assignee:
blocked_by: []
---

## Question

`viewer.html` is an embedded resource, so the page a human sees comes from
whichever `--serve-viewer` process holds 6080. That process is not restarted
when the binary changes, and [058](058-the-port-answers-not-with-our-page.md)'s
identity check says it does not have to be:

    /// Identity has to survive a rebuild -- an older build of this tool left
    /// serving the port is still ours -- so it is this one stable line rather
    /// than the whole page compared byte for byte.
    public const string PageMark = "<title>passenger</title>";

Which is right for the problem 058 solved -- a *foreign* process squatting the
port, where the remedy is to name it and refuse -- and wrong for the case that
actually happened. A `--serve-viewer` from a build no longer in the working
tree passed the check, kept the port, and served its own compiled-in copy of
the page. Three committed fixes to the viewer were invisible to the human
testing them, every tool call reported success, and the only symptom was that
nothing worked:

    pid 1437441  xs7j8nk...-passenger-0.1.0  --serve-viewer 6080   <- serving
    pid 1611820  m0fi5da...-passenger-0.1.0                        <- running

    curl 127.0.0.1:6080 | grep -c clipboardPasteFrom  ->  0

**This is not only about rebuilds.** Two live sessions on one machine share the
port the same way, so the assets a human is handed are whichever passenger
started first -- which nothing in the reply says, and which is exactly the class
of correlation bug this map was opened for.

## What to decide

- **What "ours" should mean.** The narrow fix is a mark that carries a build
  identity -- the assembly's informational version, or a hash of the page
  itself -- so `Serving(port)` can distinguish ours-and-current from
  ours-and-stale.
- **What to do with a stale-but-ours server.** Refusing is wrong here: the rule
  that this tool "will not kill a process it did not start" exists to protect
  *other people's* processes, and this one is ours by construction. Killing and
  re-execing it is the obvious remedy, and it is what a human does by hand
  today. Worth stating in the ticket that closes this, so the exception is
  deliberate rather than a hole in the rule.
- **Whether the page should be a file rather than a resource.** Serving it from
  the store path the running binary knows would make the whole question moot for
  rebuilds, at the cost of a runtime path that can be missing. Probably not
  worth it -- but it is the alternative, and it should be dismissed on purpose.
- **What the reply should say.** `showBrowser` returns a URL today. If a viewer
  can be served by a different build than the one answering the call, saying so
  once is cheaper than the hour this cost.

## How it was found

Ticket 063's viewer work -- clipboard both directions, focus on connect, drops
refused -- tested by a human immediately after the commit, with all three
landing in a binary nothing was running.
