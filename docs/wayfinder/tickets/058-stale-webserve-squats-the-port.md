---
id: 058
title: A stale predecessor on the viewer port makes showBrowser hand out a 404
labels: [wayfinder:task]
status: open
assignee: lyh (via Claude)
blocked_by: []
---

## Question

`showBrowser` returned normally --

    opened google-chrome-stable on http://127.0.0.1:6080/?ws=127.0.0.1:5900, scale 1.601562

-- and the human looking at the window got Python's stock error page:

    Error code: 404
    Message: File not found.

Nothing was wrong with the session. `browserStatus` said `daemon: up`,
`session: live`, `onScreen: True`, `wedged: none`, `screenClaims: 1`, and
wayvnc was listening on 5900. The page the viewer is served from was the only
thing missing, and the tool that opened it never looked.

## What is actually on the port

Not us. `ss -lptn 'sport = :6080'` names pid 620775:

    /home/lyh/agent-browser/.venv/bin/python3 -m ab.webserve 6080

Started **Aug 23 00:54** and still running. `/home/lyh/agent-browser` does not
exist any more -- this is the Python predecessor from before the rename, left
holding the socket by a machine that has since moved to
`/home/lyh/pullground/passenger`.

The two servers do not agree on where the viewer page lives, and the
difference is exactly the request that failed:

| request | stale python | this repo |
|---|---|---|
| `/` | **404** | the embedded viewer page |
| `/index.html` | 404 | the embedded viewer page |
| `/novnc/vnc.html` | 200 | 200 |
| `/novnc/core/rfb.js` | 200 | 200 |

`Webserve.TranslatePath` (`src/Passenger/Webserve.cs:90`) returns `""` for `/`
and `/index.html`, meaning "the embedded viewer page", and serves `/novnc/*`
off `NovncRoot()`. The predecessor only ever had the second half. So every
asset the page would pull is reachable, and the page itself is not -- which is
why this looks like a broken URL rather than a dead port.

## Why nothing noticed

`Webserve.Ensure` (`src/Passenger/Webserve.cs:202`) opens with

```csharp
if (Listening(port))
{
    return true;
}
```

and `Listening` (`:191`) is `Sessions.IsListening(host, port)` -- a socket
probe. It answers "is something there", and it is standing in for "is *this*
there". Those are the same question only while this machine has never run
another thing on 6080, which stopped being true the day the project was
renamed.

So `Ensure` returns true without starting anything, `Present.PageUrl()`
(`Present.cs:84`) composes `{ViewerUrl}?ws={host}:{port}` against a server that
has no route for it, and `showBrowser` reports the URL as though it had been
served. The C# webserve is never reached, so no amount of correctness in
`TranslatePath` can help: it is not the process answering.

This is the same shape as [042](042-attach-hangs-on-pending-navigation.md) --
a health check that passes on the wrong evidence -- and the same shape as this
tool's own advice about soft walls: *a page that arrives is not the same as the
page you asked for*.

## Two halves, and the second one is the general fix

**Identity, not liveness.** A socket probe cannot tell a predecessor from an
incumbent. The cheap fix is to fetch `/` once and check it is the viewer page,
which is one request against a server that is by definition local and up. Then
a squatter is *detectable*, and `Ensure` has a real choice to make. What it
should do when it detects one is the part worth arguing: taking the port means
killing a process this tool did not start, which is the kind of destructive act
[057](057-delete-the-cli.md) deliberately kept out of agent hands. Refusing
with a message that names the pid and the command line is probably right, and
is strictly better than today's silent success.

**A tool that reports a URL should have fetched it.** Even with identity
checking, `showBrowser` is a handoff to a *human*, and the cost of handing over
a broken page is that the person stares at a 404 and reports the tool as
broken -- which is exactly what happened here. It already blocks on
`waitSeconds` and already polls for `until: "unblocked"`; a single GET before
returning is nothing beside that, and it converts a class of silent failures
into a named one. Note this is measurement, not interpretation: whether the
page *renders* stays the human's judgement, but whether it was *served* is a
fact the tool can and should have.

## Repro

With the stale process alive, any `showBrowser` reproduces it. Without one:

```sh
python3 -m http.server 6080 --bind 127.0.0.1 &   # any squatter with no `/`
# showBrowser -> returns a URL, human gets 404
```

Workaround for whoever hits this before it is fixed: `kill` the process that
`ss -lptn 'sport = :6080'` names, then call `showBrowser` again -- `Ensure`
will find the port free and start the real one.

## Notes

Found while watching a scraping agent work, on 2026-08-24. The viewer had
presumably been broken on this machine since the rename; nothing had asked for
a window in between, which is its own small lesson about how long a silent
failure can sit in a path only humans use.
