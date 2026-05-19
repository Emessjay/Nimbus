#!/usr/bin/env bash
# Called by a critic to mark its review complete.
#
# Usage:
#   ./scripts/critic-done.sh "<one-line summary of findings>"
#
# Must be run from the home repo's main checkout (critics do not have
# a worktree — they observe the merged code in place). Refuses if
# .auditor-state/<slug>.critique.md is missing or empty, so the critic
# cannot mark done before writing its critique.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 \"<summary>\"" >&2
    exit 1
fi

summary="$*"

main_repo=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -z "$main_repo" ]]; then
    echo "error: not inside a git repo" >&2
    exit 1
fi

# Critics work in the main checkout, so $main_repo is also where the
# state files live. The critic env exports NIMBUS_WORKER_SLUG; prefer
# that, but fall back to scanning .auditor-state for the active critic
# state file in case the env is missing for some reason.
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
critique_file="$state_dir/$slug.critique.md"

if [[ ! -f "$state_file" ]]; then
    echo "error: no state file at $state_file" >&2
    exit 1
fi

role=$(grep '^role=' "$state_file" | head -1 | cut -d= -f2-)
if [[ "$role" != "critic" ]]; then
    echo "error: state file says role=$role, expected critic" >&2
    exit 1
fi

if [[ ! -f "$critique_file" ]]; then
    echo "error: critique file $critique_file does not exist" >&2
    echo "       write your critique before calling critic-done.sh." >&2
    exit 1
fi
if [[ ! -s "$critique_file" ]]; then
    echo "error: critique file $critique_file is empty" >&2
    echo "       write your critique before calling critic-done.sh." >&2
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

if [[ -z "${NIMBUS_TEST_MODE:-}" ]]; then
    osascript -e "display notification \"$slug: $summary\" with title \"Nimbus critic done\"" 2>/dev/null || true
    "$main_repo/scripts/wake-auditor.sh" "$slug" "done" 2>/dev/null || true
fi

echo "marked critic $slug done."
echo "  critique: $critique_file"
