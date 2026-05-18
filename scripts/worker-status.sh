#!/usr/bin/env bash
# Show detailed status for one worker.
#
# Usage:
#   ./scripts/worker-status.sh <slug>

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <slug>" >&2
    exit 1
fi

slug="$1"
repo_root="$(git rev-parse --show-toplevel)"
state_dir="$repo_root/.auditor-state"
state_file="$state_dir/$slug.state"
task_file="$state_dir/$slug.task"
mailbox="$state_dir/$slug.mailbox"

if [[ ! -f "$state_file" ]]; then
    echo "error: no state for $slug at $state_file" >&2
    exit 1
fi

echo "=== $slug ==="
echo
echo "-- state --"
cat "$state_file"
echo

echo "-- task --"
if [[ -f "$task_file" ]]; then
    cat "$task_file"
else
    echo "(missing)"
fi
echo

if [[ -f "$mailbox" ]]; then
    echo "-- pending mailbox messages --"
    cat "$mailbox"
    echo
fi

worktree_path=$(grep '^worktree_path=' "$state_file" | head -1 | cut -d= -f2-)
if [[ -d "$worktree_path" ]]; then
    echo "-- diff stat (main...HEAD) --"
    git -C "$worktree_path" diff --stat main...HEAD 2>/dev/null || echo "(could not diff)"
    echo
    echo "-- commits ahead of main --"
    git -C "$worktree_path" log --oneline main..HEAD 2>/dev/null || echo "(none)"
fi
