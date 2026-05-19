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
if [[ "$branch" != "main" ]]; then
    echo "error: HEAD is on '$branch', expected 'main'" >&2
    exit 1
fi

main_repo=$(git rev-parse --show-toplevel)
state_dir="$main_repo/.auditor-state"

# Prefer the env var set by nimbus-worker.sh; fall back to scanning
# state files for the active lightweight (cap 1).
slug="${NIMBUS_WORKER_SLUG:-}"
if [[ -z "$slug" ]]; then
    shopt -s nullglob
    for sf in "$state_dir"/*.state; do
        role=$(grep '^role=' "$sf" | head -1 | cut -d= -f2-)
        s=$(grep '^state=' "$sf" | head -1 | cut -d= -f2-)
        if [[ "$role" == "lightweight" && ( "$s" == "running" || "$s" == "blocked" ) ]]; then
            slug=$(grep '^slug=' "$sf" | head -1 | cut -d= -f2-)
            break
        fi
    done
    shopt -u nullglob
fi

if [[ -z "$slug" ]]; then
    echo "error: could not determine lightweight slug (no active lightweight state file)" >&2
    exit 1
fi

state_file="$state_dir/$slug.state"

if [[ ! -f "$state_file" ]]; then
    echo "error: no state file at $state_file" >&2
    exit 1
fi

# Informational: tell the lightweight if it already committed work the
# auditor will see on main. Not a refusal — partial commits are allowed.
start_sha=$(grep '^start_sha=' "$state_file" | head -1 | cut -d= -f2- || true)
if [[ -n "$start_sha" ]]; then
    ahead=$(git rev-list --count "$start_sha..HEAD" 2>/dev/null || echo "0")
    if [[ "$ahead" -gt 0 ]]; then
        echo "note: you committed $ahead commit(s) before blocking; the auditor will see them on \`main\`." >&2
    fi
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
