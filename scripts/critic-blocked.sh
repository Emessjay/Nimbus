#!/usr/bin/env bash
# Called by a critic when it cannot reach the feature under review.
#
# Usage:
#   ./scripts/critic-blocked.sh "<reason>"
#
# Examples:
#   ./scripts/critic-blocked.sh "tauri dev exits with port-in-use"
#   ./scripts/critic-blocked.sh "login submit button does nothing"
#
# The auditor will see "critic <slug> blocked: <reason>" on the next
# prompt and decide whether to fix the underlying issue, rephrase the
# brief, or cancel. The reason is prefixed [CRITIC] so the auditor can
# distinguish from worker / lightweight / debugger blocks.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 \"<reason>\"" >&2
    exit 1
fi

reason="$*"

main_repo=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -z "$main_repo" ]]; then
    echo "error: not inside a git repo" >&2
    exit 1
fi

slug="${NIMBUS_WORKER_SLUG:-}"
state_dir="$main_repo/.auditor-state"
if [[ -z "$slug" ]]; then
    shopt -s nullglob
    for sf in "$state_dir"/*.state; do
        role=$(grep '^role=' "$sf" | head -1 | cut -d= -f2-)
        s=$(grep '^state=' "$sf" | head -1 | cut -d= -f2-)
        if [[ "$role" == "critic" && "$s" == "running" ]]; then
            slug=$(grep '^slug=' "$sf" | head -1 | cut -d= -f2-)
            break
        fi
    done
    shopt -u nullglob
fi
if [[ -z "$slug" ]]; then
    echo "error: cannot determine critic slug (NIMBUS_WORKER_SLUG unset and no running critic found)" >&2
    exit 1
fi

state_file="$state_dir/$slug.state"
if [[ ! -f "$state_file" ]]; then
    echo "error: no state file at $state_file" >&2
    exit 1
fi

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
prefixed_reason="[CRITIC] $reason"
tmp=$(mktemp)
while IFS= read -r line; do
    case "$line" in
        state=*)          echo "state=blocked" ;;
        updated_at=*)     echo "updated_at=$now" ;;
        blocked_reason=*) echo "blocked_reason=$prefixed_reason" ;;
        *)                echo "$line" ;;
    esac
done < "$state_file" > "$tmp"
mv "$tmp" "$state_file"

osascript -e "display notification \"$slug: $reason\" with title \"Nimbus critic blocked\"" 2>/dev/null || true
"$main_repo/scripts/wake-auditor.sh" "$slug" "blocked" 2>/dev/null || true

echo "marked critic $slug blocked: $reason"
