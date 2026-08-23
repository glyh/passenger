# Issue tracker

This repo has no remote and no hosted tracker, so issues live in the
repository as markdown. Git history is the audit trail.

## Layout

    docs/wayfinder/map.md              the map (label wayfinder:map)
    docs/wayfinder/tickets/NNN-*.md    child issues of the map

The filename number is the issue id. Ids are never reused.

## Ticket front matter

```yaml
---
id: 001
title: <the name -- how it is referred to everywhere>
labels: [wayfinder:research | wayfinder:prototype | wayfinder:grilling | wayfinder:task]
status: open | closed
assignee: <who claimed it, or empty>
blocked_by: [<ids that must close first>]
---
```

## Wayfinding operations

- **Map**: `docs/wayfinder/map.md`.
- **Child issues**: every file under `docs/wayfinder/tickets/`.
- **Blocking**: the `blocked_by` list. No native dependency graph exists
  here, so this body convention stands in for one.
- **Claim**: set `assignee` and commit, before doing any work. An open
  ticket with an empty assignee is unclaimed.
- **Frontier**: open tickets, unassigned, whose `blocked_by` entries are
  all closed:

      docs/wayfinder/frontier.sh

- **New ticket**: never pick the number by looking at the directory. Two
  sessions that read at the same time pick the same one, which has happened
  four times here. Ask for it instead, and edit the file it prints:

      docs/wayfinder/frontier.sh new <slug> "<title>" [label]

  The id is claimed by an exclusive create under `docs/wayfinder/ids/`, so
  concurrent callers get different numbers. Those entries are never removed --
  a spent id stays spent even if the run died before writing the ticket.

  The ledger is local and gitignored. Do not commit it, and do not reach for
  `git add -f` when git says it is ignored -- entries were tracked once and
  were deliberately removed in 6c1ab47. It guards one thing only: two live
  sessions sharing this working tree in the same moment, which is why it need
  not outlive the tree. Everything longer-lived is already covered, because
  the allocator reads ticket filenames and git history alongside it, and a
  committed ticket puts its number out of reach for good.

- **Resolve**: append a `## Answer` section to the ticket, set
  `status: closed`, and add a one-line pointer to the map's
  Decisions-so-far.
