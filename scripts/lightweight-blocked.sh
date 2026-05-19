#!/usr/bin/env bash
# Called by a lightweight when "trivial" turns out to be not so trivial.
#
# Usage:
#   ./scripts/lightweight-blocked.sh "<reason>"
#
# The auditor will see "lightweight <slug> blocked: <reason>" on the
# next prompt and decide whether to rephrase the task, cancel, or
# escalate to a real worker. The blocked reason is prefixed
# [LIGHTWEIGHT] so the auditor can distinguish from worker blocks.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 \"<reason>\"" >&2
    exit 1
fi

reason="$*"

branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$branch" != fix/* ]]; then
    echo "error: HEAD is on '$branch', not a fix/<slug> branch" >&2
    exit 1
fi
slug="${branch#fix/}"

main_repo=$(git rev-parse --show-toplevel)
state_file="$main_repo/.auditor-state/$slug.state"

if [[ ! -f "$state_file" ]]; then
    echo "error: no state file at $state_file" >&2
    exit 1
fi

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
prefixed_reason="[LIGHTWEIGHT] $reason"
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

if [[ -z "${NIMBUS_TEST_MODE:-}" ]]; then
    osascript -e "display notification \"$slug: $reason\" with title \"Nimbus lightweight blocked\"" 2>/dev/null || true
    "$main_repo/scripts/wake-auditor.sh" "$slug" "blocked" 2>/dev/null || true
fi

echo "marked $slug blocked: $reason"
