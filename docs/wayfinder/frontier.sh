#!/bin/sh
# Open, unassigned tickets whose blockers are all closed.
cd "$(dirname "$0")/tickets" || exit 1
for f in *.md; do
  grep -q '^status: open' "$f" || continue
  grep -qE '^assignee: *$' "$f" || continue
  blockers=$(sed -n 's/^blocked_by: *\[\(.*\)\]/\1/p' "$f" | tr -d ' ' | tr ',' ' ')
  ready=yes
  for b in $blockers; do
    grep -q '^status: closed' "$b"-*.md 2>/dev/null || ready=no
  done
  # An `&&` here would leave the loop's last test as the script's exit status,
  # so a run that correctly skipped a blocked ticket reported failure.
  if [ "$ready" = yes ]; then
    printf '%s  %s\n' "$f" "$(sed -n 's/^title: //p' "$f")"
  fi
done
