#!/usr/bin/env bash
# Merge a completed worker's branch into main, then clean up the
# worktree and feature branch.
#
# Usage:
#   ./scripts/merge-worker.sh <slug>           # only if state == done
#   ./scripts/merge-worker.sh <slug> --force   # ignore state
#
# Run from the main repo root.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <slug> [--force]" >&2
    exit 1
fi

slug="$1"
force="${2:-}"

repo_root="$(git rev-parse --show-toplevel)"
state_dir="$repo_root/.auditor-state"
state_file="$state_dir/$slug.state"

if [[ ! -f "$state_file" ]]; then
    echo "error: no state for $slug" >&2
    exit 1
fi

branch=$(grep '^branch=' "$state_file" | head -1 | cut -d= -f2-)
worktree_path=$(grep '^worktree_path=' "$state_file" | head -1 | cut -d= -f2-)
state=$(grep '^state=' "$state_file" | head -1 | cut -d= -f2-)

if [[ "$state" != "done" && "$force" != "--force" ]]; then
    echo "error: worker state is '$state', not 'done'." >&2
    echo "       pass --force to merge anyway." >&2
    exit 1
fi

# Verify we are on main.
current=$(git -C "$repo_root" branch --show-current)
if [[ "$current" != "main" ]]; then
    echo "error: main repo is on '$current', not main" >&2
    exit 1
fi

# Refuse if the main repo has uncommitted changes — would clobber.
if ! git -C "$repo_root" diff --quiet || ! git -C "$repo_root" diff --cached --quiet; then
    echo "error: main worktree has uncommitted changes; commit or stash first" >&2
    exit 1
fi

git -C "$repo_root" merge "$branch"

if [[ -d "$worktree_path" ]]; then
    git -C "$repo_root" worktree remove "$worktree_path"
fi

git -C "$repo_root" branch -d "$branch" 2>/dev/null || true

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp)
while IFS= read -r line; do
    case "$line" in
        state=*)      echo "state=merged" ;;
        updated_at=*) echo "updated_at=$now" ;;
        *)            echo "$line" ;;
    esac
done < "$state_file" > "$tmp"
mv "$tmp" "$state_file"

# Drop the mailbox; the worker no longer exists.
rm -f "$state_dir/$slug.mailbox"

echo "merged $slug, removed worktree, deleted branch."
