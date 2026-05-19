#!/usr/bin/env bash
# Called by a lightweight to mark itself complete.
#
# Usage:
#   ./scripts/lightweight-done.sh "<one-line summary>"
#
# Must be run from the main checkout (lightweights do not have their own
# worktree) while HEAD is on fix/<slug>. Refuses if no commits ahead of
# main — catches the common mistake of marking done before committing.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 \"<summary>\"" >&2
    exit 1
fi

summary="$*"

branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$branch" != fix/* ]]; then
    echo "error: HEAD is on '$branch', not a fix/<slug> branch" >&2
    echo "       lightweights run on fix/<slug>; aborting." >&2
    exit 1
fi
slug="${branch#fix/}"

main_repo=$(git rev-parse --show-toplevel)
state_dir="$main_repo/.auditor-state"
state_file="$state_dir/$slug.state"

if [[ ! -f "$state_file" ]]; then
    echo "error: no state file at $state_file" >&2
    exit 1
fi

role=$(grep '^role=' "$state_file" | head -1 | cut -d= -f2-)
if [[ "$role" != "lightweight" ]]; then
    echo "error: state file says role=$role, expected lightweight" >&2
    exit 1
fi

ahead=$(git rev-list --count main..HEAD 2>/dev/null || echo "0")
if [[ "$ahead" -eq 0 ]]; then
    echo "error: no commits ahead of main on $branch" >&2
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

if [[ -z "${NIMBUS_TEST_MODE:-}" ]]; then
    osascript -e "display notification \"$slug: $summary\" with title \"Nimbus lightweight done\"" 2>/dev/null || true
    "$main_repo/scripts/wake-auditor.sh" "$slug" "done" 2>/dev/null || true
fi

echo "marked $slug done."
