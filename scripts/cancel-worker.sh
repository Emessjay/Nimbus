#!/usr/bin/env bash
# Cancel a worker: kill its tmux window, force-remove its worktree,
# delete its branch, and mark state=cancelled.
#
# Usage:
#   ./scripts/cancel-worker.sh <slug>
#
# Use when a worker has gone off the rails and you want a clean slate.
# Any uncommitted changes in the worker's worktree are LOST. Committed
# work on the feature branch is also lost (branch is force-deleted).
# The state file is preserved as a record (state=cancelled).
#
# After cancelling, spawn a fresh worker with the same or a different
# slug:
#   ./scripts/spawn-worker.sh <slug> "<reformulated task>"

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <slug>" >&2
    exit 1
fi

slug="$1"
repo_root="$(git rev-parse --show-toplevel)"
state_dir="$repo_root/.auditor-state"
state_file="$state_dir/$slug.state"

if [[ ! -f "$state_file" ]]; then
    echo "error: no state for $slug" >&2
    exit 1
fi

worktree_path=$(grep '^worktree_path=' "$state_file" | head -1 | cut -d= -f2-)
branch=$(grep '^branch=' "$state_file" | head -1 | cut -d= -f2-)
state=$(grep '^state=' "$state_file" | head -1 | cut -d= -f2-)
role=$(grep '^role=' "$state_file" | head -1 | cut -d= -f2-)
role="${role:-worker}"
pair_mode=$(grep '^pair_mode=' "$state_file" | head -1 | cut -d= -f2-)

if [[ "$state" == "merged" ]]; then
    echo "error: $role $slug was already merged; nothing to cancel" >&2
    exit 1
fi

# Kill the agent's tmux window(s) if alive. Workers use the bare slug;
# lightweights add -light; debuggers in a pair add -dbg.
if command -v tmux >/dev/null 2>&1; then
    case "$role" in
        lightweight)
            tmux kill-window -t "nimbus-workers:${slug}-light" 2>/dev/null || true
            ;;
        *)
            tmux kill-window -t "nimbus-workers:$slug" 2>/dev/null || true
            if [[ "$pair_mode" == "paired" ]]; then
                tmux kill-window -t "nimbus-workers:${slug}-dbg" 2>/dev/null || true
            fi
            ;;
    esac
fi

if [[ "$role" == "lightweight" ]]; then
    # Lightweight has no worktree — its "worktree_path" is the main
    # checkout. Switch back to main and delete the branch.
    current=$(git -C "$repo_root" branch --show-current)
    if [[ "$current" == "$branch" ]]; then
        git -C "$repo_root" checkout main 2>/dev/null || true
    fi
    git -C "$repo_root" branch -D "$branch" 2>/dev/null || true
else
    # Force-remove the worktree (uncommitted changes are discarded).
    if [[ -d "$worktree_path" ]]; then
        git -C "$repo_root" worktree remove --force "$worktree_path" 2>/dev/null || true
    fi
    # Force-delete the branch.
    git -C "$repo_root" branch -D "$branch" 2>/dev/null || true
fi

# Mark state cancelled.
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp)
while IFS= read -r line; do
    case "$line" in
        state=*)      echo "state=cancelled" ;;
        updated_at=*) echo "updated_at=$now" ;;
        *)            echo "$line" ;;
    esac
done < "$state_file" > "$tmp"
mv "$tmp" "$state_file"

# Drop the mailbox.
rm -f "$state_dir/$slug.mailbox"

echo "cancelled $role $slug:"
if [[ "$role" == "lightweight" ]]; then
    echo "  - killed tmux window nimbus-workers:${slug}-light"
    echo "  - restored main checkout to 'main'"
else
    echo "  - killed tmux window nimbus-workers:$slug"
    [[ "$pair_mode" == "paired" ]] && echo "  - killed tmux window nimbus-workers:${slug}-dbg"
    echo "  - force-removed worktree $worktree_path"
fi
echo "  - force-deleted branch $branch"
echo "  - mailbox cleared, state set to cancelled"
echo
case "$role" in
    lightweight) echo "respawn with: ./scripts/spawn-lightweight.sh $slug \"<reformulated task>\"" ;;
    *) echo "respawn with: ./scripts/spawn-worker.sh $slug \"<reformulated task>\"" ;;
esac
