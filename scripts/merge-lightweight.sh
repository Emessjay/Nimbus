#!/usr/bin/env bash
# Fast-forward a done lightweight's branch into main, kill its tmux
# window, and delete the branch. Restores the main checkout to 'main'.
#
# Usage:
#   ./scripts/merge-lightweight.sh <slug>           # only if state == done
#   ./scripts/merge-lightweight.sh <slug> --force   # ignore state
#
# Run from the main repo root by the auditor.

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

role=$(grep '^role=' "$state_file" | head -1 | cut -d= -f2-)
if [[ "$role" != "lightweight" ]]; then
    echo "error: $slug has role=$role, not lightweight; use merge-worker.sh" >&2
    exit 1
fi

branch=$(grep '^branch=' "$state_file" | head -1 | cut -d= -f2-)
state=$(grep '^state=' "$state_file" | head -1 | cut -d= -f2-)

if [[ "$state" != "done" && "$force" != "--force" ]]; then
    echo "error: lightweight state is '$state', not 'done'." >&2
    echo "       pass --force to merge anyway." >&2
    exit 1
fi

# Switch to main and fast-forward.
# The main checkout is currently on fix/<slug> (because spawn-lightweight
# checked the branch out there); we need to switch back before merging.
current=$(git -C "$repo_root" branch --show-current)
if [[ "$current" != "main" && "$current" != "$branch" ]]; then
    echo "error: main checkout is on '$current', expected '$branch' or 'main'" >&2
    exit 1
fi

if ! git -C "$repo_root" diff --quiet || ! git -C "$repo_root" diff --cached --quiet; then
    echo "error: main checkout has uncommitted changes; commit, stash, or revert before merging" >&2
    exit 1
fi

# Kill the lightweight's tmux window first — it's still running on
# fix/<slug>, and we're about to delete that branch. Letting it sit
# would leave a confused Claude session in a dead window.
if command -v tmux >/dev/null 2>&1; then
    tmux kill-window -t "nimbus-workers:${slug}-light" 2>/dev/null || true
fi

git -C "$repo_root" checkout main
git -C "$repo_root" merge --ff-only "$branch"
git -C "$repo_root" branch -d "$branch"

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

rm -f "$state_dir/$slug.mailbox"

echo "merged lightweight $slug into main; main checkout restored to 'main'."
