# Two ways a tab holds the attach open

Measured 2026-08-24 on a throwaway Chrome 151 (port 9333, `--headless=new`)
against a local server offering four ways to be slow on one port:

    /dead      accept the connection, answer nothing, ever
    /slowhead  answer the headers after 120s
    /slowbody  answer the headers now, dribble the body forever
    /fast      answer at once

The attach under test is `patchright.chromium.connect_over_cdp`, 15s timeout --
the same call `Session._attach` makes. Server, probes and the remedy matrix are
throwaway; both processes were stopped afterwards.

## 1. Only a *pre-commit* navigation hangs the attach

    tab open                                 attach
    ----------------------------------       -----------------------
    /fast, loaded                            0.2s
    /slowbody -- headers in, body forever    0.2s      <-- still loading
    /slowhead -- no headers yet              FAILED after 15.2s
    /dead     -- no headers, ever            FAILED after 15.2s

This narrows the whole problem. A page that is *genuinely slow* in the ordinary
sense -- a big document arriving over a thin pipe -- has already committed, and
costs the attach nothing. What hangs it is the window between "navigation
started" and "first response byte", and only that.

The corollary is that `/slowhead` and `/dead` are indistinguishable and always
will be: they *are* the same state until the server answers. No signal
separates them, so nothing here tries to.

## 2. There are two shapes of pre-commit tab, and they look opposite

Probed with `Page.getFrameTree`, `Page.getNavigationHistory` and
`Runtime.evaluate` on the tab's own websocket:

    tab                                  getFrameTree   frame.url   history
    ---------------------------------    ------------   ---------   ---------
    born at the dead URL                 answers <10ms  ""          ['']
    (PUT /json/new?<url>)

    about:blank tab, then navigated      NO ANSWER      --          ['about:blank']
    at the dead URL

    loaded page, then navigated          NO ANSWER      --          ['<old url>']
    at the dead URL

The second and third are ticket 012's wedge: a renderer with a document, busy
enough that it answers nothing, which `targets.unstick` already catches and
frees. Confirmed live -- `unstick: 3.0s, stuck=1`, and the next attach took
0.2s.

The first is 042's, and it is the opposite: the renderer answers everything
instantly, because it has nothing to be busy with. `unstick: 0.0s, stuck=0`,
and the next attach failed again. **What gives it away is the answer, not the
silence** -- `frame.url` is the empty string, which is Chrome for "no document
committed here at all". `about:blank` is *not* that; it is a document.

Passenger's own tabs are shape two: `context.new_page()` commits `about:blank`
before `goto`. Shape one arrives from outside the tool's own path -- a
`window.open`, a `target="_blank"` a human clicked during a handoff, a session
restore -- which is why it went unnoticed and why it lands in `orphan`.

## 3. Neither remedy works on the other's tab

For a tab born at the dead URL, each remedy applied and then attached:

    remedy                       attach after
    -------------------------    ------------------------
    nothing                      FAILED after 15.2s
    Page.stopLoading             FAILED after 15.2s      <-- answered `{}`
    Page.navigate about:blank    0.2s, tab survives
    close the target             0.2s, tab gone

`Page.stopLoading` is *answered* -- `{}` in under 10ms -- and it does clear the
pending URL: `/json/list` afterwards shows the target's url as `""`. The attach
hangs exactly as before. So the answer is no evidence the remedy worked, which
is the trap: 012's probe would have reported success here if it had ever fired.

Navigating the tab to `about:blank` frees it and keeps the tab, so the caller's
handle and its lane row survive. It costs nothing that closing would not also
cost, because a tab with no document has no document to lose. That asymmetry is
what makes the remedy affordable: the gentle remedy is unnecessary in exactly
the case where it does not work.

## 4. After the fix

The real `Session._attach`, same browser, each wedge in turn:

    wedge                status before      attach            status after
    -----------------    ---------------    --------------    ------------
    uncommitted (042)    1 uncommitted      15.5s, freed      none
    silent (012)         1 silent           18.5s, freed      none
    nothing wrong        none               0.2s              none

Both are one attach timeout plus a rescue, where 042's was previously two
timeouts and then a dead end.
