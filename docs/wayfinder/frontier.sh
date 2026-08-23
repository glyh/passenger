#!/bin/sh
# The frontier, and the one safe way to take a ticket id.
#
#   frontier.sh                              open, unassigned, unblocked
#   frontier.sh new <slug> <title> [label]   allocate an id and write the file
#
# Ids collided four times in this repo's short life, always the same way: two
# sessions read the directory, saw the same highest number, and both wrote it.
# Reading and then writing *is* the bug, so `new` does not do that. It claims
# the number with an exclusive create in `ids/`, and the kernel decides who
# won; the loser walks to the next number and claims that instead.
#
# The claim is a file of its own rather than the ticket, and that is the whole
# design. The first version claimed the id by creating `NNN.md` and then
# renaming it to `NNN-slug.md` -- which handed the number straight back, so a
# session arriving a millisecond later found `NNN.md` free and took it again.
# Twenty-four parallel runs produced eight distinct ids. A claim that is given
# back is a lock, and a lock that is released early is indistinguishable from
# no lock at all.
#
# So `ids/NNN` is never removed. It cannot go stale, because ids are never
# reused: an entry left behind by a killed run is simply a number that was
# spent, which is true whether or not the ticket got written. It is a claim
# ledger, not a second copy of the ticket list -- the tickets remain the
# record of what exists, and `spent_ids` reads them, the ledger, and git
# history together so that ids taken before this script existed are still
# off-limits.
set -e

base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dir=$base/tickets
ids=$base/ids

# --- the frontier ------------------------------------------------------

frontier() {
  cd "$dir" || exit 1
  for f in *.md; do
    grep -q '^status: open' "$f" || continue
    grep -qE '^assignee: *$' "$f" || continue
    blockers=$(sed -n 's/^blocked_by: *\[\(.*\)\]/\1/p' "$f" | tr -d ' ' | tr ',' ' ')
    ready=yes
    for b in $blockers; do
      grep -q '^status: closed' "$b"-*.md 2>/dev/null || ready=no
    done
    # An `&&` here would leave the loop's last test as the script's exit
    # status, so a run that correctly skipped a blocked ticket reported
    # failure.
    if [ "$ready" = yes ]; then
      printf '%s  %s\n' "$f" "$(sed -n 's/^title: //p' "$f")"
    fi
  done
}

# --- ids ---------------------------------------------------------------

spent_ids() {
  # Three sources, because no one of them is complete. The ledger misses
  # everything allocated before it existed; the working tree misses a ticket
  # that was renamed or deleted; git history misses a ticket that has not been
  # committed yet, which is exactly the window two live sessions share.
  for f in "$ids"/[0-9]*; do
    [ -e "$f" ] || continue
    basename -- "$f"
  done
  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    basename -- "$f" | sed -n 's/^\([0-9][0-9]*\).*/\1/p'
  done
  git -C "$dir" log --diff-filter=A --name-only --format= -- . 2>/dev/null |
    sed -n 's#.*/\([0-9][0-9]*\)[^/]*\.md$#\1#p'
}

claim_id() {
  # Start above the highest id ever spent, then walk upward until an exclusive
  # create succeeds. Both halves matter: the list keeps us off ids that are
  # taken, and the create keeps us off the id a concurrent run is taking right
  # now.
  mkdir -p "$ids"
  taken=$(spent_ids | sed 's/^0*//' | sort -n | uniq)
  i=$(printf '%s\n' "$taken" | tail -1)
  i=$(( ${i:-0} + 1 ))
  while [ "$i" -lt 1000 ]; do
    id=$(printf '%03d' "$i")
    if ! printf '%s\n' "$taken" | grep -qx "$i"; then
      if (set -C; printf '%s\n' "$1" > "$ids/$id") 2>/dev/null; then
        printf '%s\n' "$id"
        return 0
      fi
    fi
    i=$(( i + 1 ))
  done
  echo "frontier.sh: no free id below 1000" >&2
  exit 1
}

new_ticket() {
  slug=$1; title=$2; label=${3:-wayfinder:task}
  case $slug in
    '' | *[!a-z0-9-]* | -* | *-)
      echo "frontier.sh: slug must be kebab-case: $slug" >&2; exit 2 ;;
  esac
  [ -n "$title" ] || { echo "frontier.sh: a title is required" >&2; exit 2; }

  id=$(claim_id "$slug")
  file="$dir/$id-$slug.md"
  cat > "$file" <<EOF
---
id: $id
title: $title
labels: [$label]
status: open
assignee:
blocked_by: []
---

## Question

EOF
  printf '%s\n' "$file"
}

case ${1-} in
  '')  frontier ;;
  new) shift; new_ticket "${1-}" "${2-}" "${3-}" ;;
  *)   echo "usage: $0 [new <slug> <title> [label]]" >&2; exit 2 ;;
esac
