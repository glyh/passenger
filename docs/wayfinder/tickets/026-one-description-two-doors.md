---
id: 026
title: One description, two doors
labels: [wayfinder:grilling]
status: closed
assignee: lyh (via Claude)
blocked_by: []
---

## Question

The CLI and the MCP server are two hand-written surfaces over the same
service layer, and they have drifted. [Asking for a human, rather than
being guessed at](018-asking-for-a-human.md) added `tab`, `wait_seconds`
and `notify_human` to the MCP `show_browser` and deliberately did not
mirror any of them onto `agent-browser show`, because mirroring three
flags by hand is the symptom rather than the fix.

The drift is older than that ticket. `fetch` on the CLI takes
`--keep-tab`, `--close-tabs`, `--new-tab` and `--wait`, none of which the
MCP `fetch` exposes; the MCP `fetch` takes `wait_seconds`, which the CLI
spells `--handoff` plus a setting; `script` exists at both doors with
different parameter names for the same thing. Every one of those is a
defensible local choice, and together they mean a capability added in one
place is silently absent in the other, with nothing that fails when it is.

What is wanted is a single declarative description of each capability --
its parameters, their types, bounds, defaults and prose -- that both
`cyclopts` and the MCP tool schema are generated from, so the two doors
cannot disagree by accident.

To decide:

1. Where the source of truth lives. The request models in `ab/models.py`
   are the obvious candidate: `FetchRequest` and `ScriptRequest` are
   already pydantic, already carry bounds, and are already what the
   service layer takes. `show_browser` has no request model at all, which
   is part of why it drifted -- so this may be as much about giving every
   capability one as about generating from it.
2. What the description has to express that a pydantic model does not.
   Per-door prose is the hard one: the MCP `fetch` docstring is written
   for an agent and says things a human at a terminal does not need, and
   `--help` wants a line where a tool schema wants a paragraph.
3. Whether the two doors genuinely want the same parameters. 018 argued
   they do not: `wait_seconds` and `notify_human` are ways of reaching a
   human who is not the caller, and on the CLI the caller *is* the human.
   If that is right, the description needs a way to say "this door only",
   and the interesting question becomes whether that escape hatch gets
   used honestly or becomes where drift hides again.
4. What this costs in indirection. Two hand-written surfaces are dumb and
   readable; a generator is neither. It has to pay for itself in more than
   tidiness -- the case is that a missing parameter is currently invisible,
   and generation makes it impossible rather than merely noticed.
5. Whether it survives [Whether this moves to
   C#](023-rewriting-into-csharp.md). If the port happens, a Python
   generator is thrown away -- but the *problem* is not, and a port is
   exactly the moment a second surface gets rebuilt by hand from the
   first. Worth knowing whether this is a thing to do now or a thing the
   port should be told about.

## Most of this went with `fetch`

*Recorded 2026-08-24.* [Delete fetch](047-one-door-script.md) removed the tool
that supplied nearly every example above. `fetch`'s `--keep-tab`,
`--close-tabs`, `--new-tab` and `--wait`, and the MCP `fetch`'s `wait_seconds`
against the CLI's `--handoff`, are all gone with the door they were on. `script`
lost `mode` and `read_page` at the same time, so what is left of it is
`source`, `lane`, `tab` and a timeout at both surfaces -- which do not
currently disagree.

What survives of the question:

- **`show_browser` still exists only on the MCP side**, and now carries `tab`,
  `wait_seconds`, `notify_human`, `ttl_minutes` and `until`. That is five
  parameters on a tool the CLI does not have at all, and
  [018](018-asking-for-a-human.md) argued that is correct rather than drift --
  at a terminal the caller *is* the human.
- **The generator's case is weaker and its cost is unchanged.** With two verbs
  that agree, there is little for a single description to keep in step, and
  decision 5's question -- whether it survives a port -- was answered
  sideways: [023](023-rewriting-into-csharp.md) on .NET generates the MCP
  schema from the method signature already, bounds and prose included.

Re-read before claiming. This may now be small enough to close as answered by
subtraction.

## The one surviving claim is now wrong

*Recorded 2026-08-24.* The note above says `show_browser` still exists only on
the MCP side. It does not: the C# CLI has both verbs --
`src/Passenger.Cli/Program.cs:213` (`show`) and `:233` (`hide`). What is true is
narrower and is still this ticket:

**`showBrowser` takes six parameters at the MCP door and one at the CLI.**
`Tools.cs:250` takes `lane`, `tab`, `waitSeconds`, `notifyHuman`, `ttlMinutes`
and `until`; `show` takes a lane and nothing else.
[018](018-asking-for-a-human.md) argued that is correct rather than drift --
reaching a human who is not the caller is meaningless at a terminal where the
caller *is* the human -- and `until="unblocked"`, which
[047](047-one-door-script.md) added, is the one of the five that argument does
not obviously cover. It is not about a human at all; it is a wait on a page
state, and there is no reason a person at a terminal would not want it.

The rest of the doors, counted after the port: MCP has ten tools; the CLI has
`script`, `tabs`, `open`, `close-tabs`, `serve`, `stop`, `show`, `hide` and
`status`.
`open`, `serve`, `stop` and `status` have no MCP counterpart and should not --
they are daemon administration. So the honest surface is *two verbs in common*,
one of which agrees exactly and one of which differs by four parameters that 018
already ruled on.

**What this does to the generator's case.** [023](023-rewriting-into-csharp.md)
settled decision 5 sideways: .NET generates the MCP schema from the method
signature, `[Description]` and bounds included, and System.CommandLine replaced
cyclopts "at more lines for the same contract -- which makes 026 slightly worse,
not better". So one door already generates and the other is hand-written, which
is the asymmetric version of what this ticket asked for, and the gap between them
is now a single parameter list that a human can hold in their head.

Decisions 1 and 2 are dead as written: `ab/models.py` and its pydantic request
models are gone with the Python door, and "what a pydantic model cannot express"
is now "what a C# parameter list plus `[Description]` cannot express" -- which
is a different and much smaller question, since the attributes already carry the
prose.

**Recommendation for whoever claims this.** Close it, and spend the ticket on
the one live disagreement instead: whether `until` belongs on `passenger show`.
A generator for two verbs, one of which is a single string, cannot pay for
itself.

## Closed: there is no second door to keep in step

*Recorded 2026-08-24.* Answered by subtraction, further than the section above
imagined. Grilling the recommendation to "spend the ticket on the one live
disagreement instead" started with the question this ticket never asked -- who
uses the CLI -- and the answer is nobody. The owner has never run it; no test
invokes it; `skills/` never names it. The profile this tool exists to keep warm
was logged in through the *MCP* door, so even `passenger open <url> --show`, the
workflow `Lanes.cs:101` reserves a whole lane for, has never been performed.

[057](057-delete-the-cli.md) deletes it, keeping `stop` alone and folding that
into `Passenger.Mcp` as a verb. With one door there is nothing to generate
twice.

Corrections this ticket earned on its way out, since both of its own counts were
wrong:

- **"Two verbs in common" undercounted.** It counted names, and the names
  differ. By behaviour, six of the ten MCP tools have a CLI counterpart:
  `script`, `listTabs`/`tabs`, `closeTabs`/`close-tabs`,
  `browserStatus`/`status`, `showBrowser`/`show`, `hideBrowser`/`hide`.
- **The drift ran both ways, not one.** Four of the six leaned CLI-wide
  (`--json`, `--force`, an optional tab list covering `closeAllTabs`, and
  `status`'s `launch:`/`recognises:`); only `showBrowser` leaned the other way.
  `status` and `browserStatus` disagreed in both directions at once -- the CLI
  never printed `screenClaims`.

And the finding that outlives the ticket: every difference except one followed a
statable rule. What the CLI had extra served a human at a terminal; what MCP had
extra reached a human who is *not* the caller ([018](018-asking-for-a-human.md))
or managed a lane the CLI did not need. The exception was `until="unblocked"`,
which is a wait on page state and belonged at both doors -- the single genuine
drift on the whole surface, and now moot.

**The alternative that was nearly built.** Before deletion was on the table, the
cheap answer to this ticket was a conformance test rather than a generator:
reflect over both doors, subtract the parameter lists, and fail unless every
difference is declared in one file beside its reason. That is 026's actual
stated goal -- "makes it impossible rather than merely noticed" -- for about
forty lines and no indirection, with the declaration file doubling as the
generator's spec if the list ever grew fast enough to justify one. It needed two
doors. Recorded here because the *shape* is reusable: when two surfaces must
agree, checking is much cheaper than generating, and the exception list is where
the reasons finally get written down.
