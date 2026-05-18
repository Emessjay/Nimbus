#!/usr/bin/env bash
# Called by a worker to mark itself complete.
#
# Usage:
#   ./scripts/worker-done.sh "<one-line summary>"
#
# Must be run from inside the worker's worktree (cwd basename must
# match nimbus-<slug>). Refuses if no commits ahead of main — this
# catches the common mistake of marking done before committing.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 \"<summary>\"" >&2
    exit 1
fi

summary="$*"

worktree="$(git rev-parse --show-toplevel)"
worktree_name="${worktree##*/}"
if [[ "$worktree_name" != nimbus-* ]]; then
    echo "error: not in an nimbus-<slug> worktree (cwd is $worktree)" >&2
    exit 1
fi
slug="${worktree_name#nimbus-}"

# Resolve the main repo (the first entry from git worktree list).
main_repo=$(git worktree list --porcelain | awk '/^worktree / { print $2; exit }')
state_dir="$main_repo/.auditor-state"
state_file="$state_dir/$slug.state"

if [[ ! -f "$state_file" ]]; then
    echo "error: no state file at $state_file" >&2
    exit 1
fi

# Refuse if no commits ahead of main.
ahead=$(git rev-list --count main..HEAD 2>/dev/null || echo "0")
if [[ "$ahead" -eq 0 ]]; then
    echo "error: no commits ahead of main on $(git branch --show-current)" >&2
    echo "       commit your work before marking the task done." >&2
    exit 1
fi

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp)
while IFS= read -r line; do
    case "$line" in
        state=*)      echo "state=done" ;;
        updated_at=*) echo "updated_at=$now" ;;
        summary=*)    echo "summary=$summary" ;;
        *)            echo "$line" ;;
    esac
done < "$state_file" > "$tmp"
mv "$tmp" "$state_file"

osascript -e "display notification \"$slug: $summary\" with title \"Nimbus worker done\"" 2>/dev/null || true
"$main_repo/scripts/wake-auditor.sh" "$slug" "done" 2>/dev/null || true

echo "marked $slug done."
