#!/usr/bin/env bash
# Called by a debugger to escalate something to the auditor — used when
# the spec has a gap, the worker's approach is fundamentally wrong, or
# the two of you genuinely disagree on something the spec doesn't
# settle.
#
# Usage:
#   ./scripts/debugger-blocked.sh "<reason>"

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 \"<reason>\"" >&2
    exit 1
fi

reason="$*"

worktree="$(git rev-parse --show-toplevel)"
worktree_name="${worktree##*/}"
if [[ "$worktree_name" != nimbus-* ]]; then
    echo "error: not in an nimbus-<slug> worktree" >&2
    exit 1
fi
slug="${worktree_name#nimbus-}"

main_repo=$(git worktree list --porcelain | awk '/^worktree / { print $2; exit }')
state_dir="$main_repo/.auditor-state"
state_file="$state_dir/$slug.state"
review_log="$state_dir/$slug.review.log"

if [[ ! -f "$state_file" ]]; then
    echo "error: no state for $slug" >&2
    exit 1
fi

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
prefixed="[DEBUGGER] $reason"
tmp=$(mktemp)
while IFS= read -r line; do
    case "$line" in
        state=*)          echo "state=blocked" ;;
        updated_at=*)     echo "updated_at=$now" ;;
        blocked_reason=*) echo "blocked_reason=$prefixed" ;;
        *)                echo "$line" ;;
    esac
done < "$state_file" > "$tmp"
mv "$tmp" "$state_file"

{
    echo "[$now] DEBUGGER BLOCKED:"
    echo "$reason"
    echo ""
} >> "$review_log"

if [[ -z "${NIMBUS_TEST_MODE:-}" ]]; then
    osascript -e "display notification \"$slug: $reason\" with title \"Nimbus debugger blocked\"" 2>/dev/null || true
    "$main_repo/scripts/wake-auditor.sh" "$slug" "blocked" 2>/dev/null || true
fi

echo "blocked $slug for auditor decision: $reason"
