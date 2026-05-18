#!/usr/bin/env bash
# Called by a worker to signal that it needs the auditor to decide
# something before it can proceed.
#
# Usage:
#   ./scripts/worker-blocked.sh "<reason / question>"
#
# Must be run from inside the worker's worktree.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 \"<reason>\"" >&2
    exit 1
fi

reason="$*"

worktree="$(git rev-parse --show-toplevel)"
worktree_name="${worktree##*/}"
if [[ "$worktree_name" != nimbus-* ]]; then
    echo "error: not in an nimbus-<slug> worktree (cwd is $worktree)" >&2
    exit 1
fi
slug="${worktree_name#nimbus-}"

main_repo=$(git worktree list --porcelain | awk '/^worktree / { print $2; exit }')
state_dir="$main_repo/.auditor-state"
state_file="$state_dir/$slug.state"

if [[ ! -f "$state_file" ]]; then
    echo "error: no state file at $state_file" >&2
    exit 1
fi

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp)
while IFS= read -r line; do
    case "$line" in
        state=*)          echo "state=blocked" ;;
        updated_at=*)     echo "updated_at=$now" ;;
        blocked_reason=*) echo "blocked_reason=$reason" ;;
        *)                echo "$line" ;;
    esac
done < "$state_file" > "$tmp"
mv "$tmp" "$state_file"

osascript -e "display notification \"$slug needs input: $reason\" with title \"Nimbus worker blocked\"" 2>/dev/null || true
"$main_repo/scripts/wake-auditor.sh" "$slug" "blocked" 2>/dev/null || true

echo "marked $slug blocked."
