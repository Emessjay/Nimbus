#!/usr/bin/env bash
# Spawn a lightweight Claude in the main checkout for a trivial fix.
#
# Usage:
#   ./scripts/spawn-lightweight.sh <slug> <task | @path/to/file>
#
# Unlike spawn-worker.sh, a lightweight does NOT get its own worktree.
# It branches the main checkout to fix/<slug>, makes its tiny edit,
# commits there, and reports done. The auditor then fast-forwards
# fix/<slug> into main with merge-lightweight.sh. While the lightweight
# is alive, the main checkout is on fix/<slug> — the auditor sees
# whatever the lightweight is working on.
#
# Cap: 1 lightweight concurrent. Reserved for quick, single-shot fixes
# the auditor is confident about — anything from a typo to a small
# targeted bug fix, as long as it doesn't need test runs, iteration,
# or touch many files. If the work would benefit from a debugger
# review pass or needs tests to validate, use spawn-worker.sh or
# spawn-pair.sh instead.

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "usage: $0 <slug> <task | @path/to/file>" >&2
    exit 1
fi

slug="$1"
shift
task="$*"

if [[ ! "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "error: slug must be lowercase alphanumeric with dashes, got: $slug" >&2
    exit 1
fi
case "$slug" in
    *-dbg|*-light)
        echo "error: slug must not end in -dbg or -light (reserved tmux window suffixes)" >&2
        exit 1
        ;;
esac

if [[ "$task" == @* ]]; then
    task_path="${task#@}"
    if [[ ! -f "$task_path" ]]; then
        echo "error: task file $task_path does not exist" >&2
        exit 1
    fi
    task=$(cat "$task_path")
fi

if [[ -z "$task" ]]; then
    echo "error: task is empty" >&2
    exit 1
fi

if ! command -v tmux >/dev/null 2>&1; then
    echo "error: tmux is not installed. Install with: brew install tmux" >&2
    exit 1
fi

repo_root="$(git rev-parse --show-toplevel)"
state_dir="$repo_root/.auditor-state"
mkdir -p "$state_dir"

# Preflight: must be on main with no uncommitted changes.
current_branch=$(git -C "$repo_root" branch --show-current)
if [[ "$current_branch" != "main" ]]; then
    echo "error: main checkout is on '$current_branch', not main" >&2
    echo "       a lightweight cannot start unless the auditor is on main." >&2
    exit 1
fi
if ! git -C "$repo_root" diff --quiet || ! git -C "$repo_root" diff --cached --quiet; then
    echo "error: main checkout has uncommitted changes; commit, stash, or revert before spawning a lightweight" >&2
    git -C "$repo_root" status --short >&2
    exit 1
fi

# Cap: at most one lightweight active at a time.
shopt -s nullglob
for sf in "$state_dir"/*.state; do
    role=$(grep '^role=' "$sf" | head -1 | cut -d= -f2-)
    s=$(grep '^state=' "$sf" | head -1 | cut -d= -f2-)
    if [[ "$role" == "lightweight" && ( "$s" == "running" || "$s" == "blocked" ) ]]; then
        existing=$(grep '^slug=' "$sf" | head -1 | cut -d= -f2-)
        echo "error: lightweight '$existing' is already $s (cap is 1)" >&2
        echo "       merge, cancel, or wait for it to finish first." >&2
        exit 1
    fi
done
shopt -u nullglob

# Refuse if a state file with this slug already exists in an active state.
if [[ -f "$state_dir/$slug.state" ]]; then
    existing_state=$(grep '^state=' "$state_dir/$slug.state" | head -1 | cut -d= -f2-)
    if [[ "$existing_state" == "running" || "$existing_state" == "blocked" ]]; then
        echo "error: '$slug' is already $existing_state" >&2
        exit 1
    fi
fi

branch="fix/$slug"

# Create the branch from main and check it out in the main checkout.
# This DOES switch the main checkout's HEAD — that's the price of
# operating without a worktree. merge-lightweight.sh restores main.
if git -C "$repo_root" rev-parse --verify "$branch" >/dev/null 2>&1; then
    echo "error: branch $branch already exists; cancel or merge the prior lightweight first" >&2
    exit 1
fi
git -C "$repo_root" checkout -b "$branch"

session_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "$task" > "$state_dir/$slug.task"
cat > "$state_dir/$slug.state" <<EOF
slug=$slug
role=lightweight
state=running
spawned_at=$now
updated_at=$now
worktree_path=$repo_root
branch=$branch
session_id=$session_id
effort=medium
model=sonnet
summary=
blocked_reason=
EOF

rm -f "$state_dir/$slug.mailbox"

tmux_session="nimbus-workers"
window_name="${slug}-light"
worker_cmd="$repo_root/scripts/nimbus-worker.sh --role lightweight $slug"

# Kill any stale window with this name.
if tmux list-windows -t "$tmux_session" -F "#{window_name}" 2>/dev/null | grep -qx "$window_name"; then
    tmux kill-window -t "$tmux_session:$window_name" 2>/dev/null || true
fi

if tmux has-session -t "$tmux_session" 2>/dev/null; then
    tmux new-window -t "$tmux_session:" -n "$window_name" -c "$repo_root" "$worker_cmd"
else
    tmux new-session -d -s "$tmux_session" -n "$window_name" -c "$repo_root" "$worker_cmd"
fi

echo "spawned lightweight: $slug"
echo "  branch:     $branch  (main checkout is now on this branch)"
echo "  session_id: $session_id"
echo "  effort:     medium  (sonnet)"
echo "  task:       $(echo "$task" | head -1 | cut -c1-80)$([[ $(echo "$task" | wc -l) -gt 1 ]] && echo ' ...')"
echo
echo "attach with: tmux attach -t $tmux_session"
echo
echo "NOTE: the main checkout will return to 'main' when you run:"
echo "      ./scripts/merge-lightweight.sh $slug"
