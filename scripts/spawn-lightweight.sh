#!/usr/bin/env bash
# Spawn a lightweight Claude in the main checkout for a trivial fix.
#
# Usage:
#   ./scripts/spawn-lightweight.sh <slug> <task | @path/to/file>
#
# Unlike spawn-worker.sh, a lightweight does NOT get its own worktree
# and does NOT create a branch. It runs in the main checkout, on `main`,
# and commits directly to `main`. Spawn records the current HEAD into
# the state file as `start_sha=<sha>` so the auditor can diff the
# lightweight's contribution with `git diff $start_sha..HEAD`, and so
# `cancel-worker.sh` can `git revert $start_sha..HEAD` cleanly if
# things go wrong.
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
    *-dbg|*-light|*-crit)
        echo "error: slug must not end in -dbg, -light, or -crit (reserved tmux window suffixes)" >&2
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
# Skip terminal-state files first — they're noise for this cap check
# AND they may predate the `role=` field in legacy projects, so reading
# role would trip pipefail.
shopt -s nullglob
for sf in "$state_dir"/*.state; do
    s=$(grep '^state=' "$sf" | head -1 | cut -d= -f2- || true)
    case "$s" in
        running|blocked) ;;
        *) continue ;;
    esac
    role=$(grep '^role=' "$sf" | head -1 | cut -d= -f2- || true)
    if [[ "$role" == "lightweight" ]]; then
        existing=$(grep '^slug=' "$sf" | head -1 | cut -d= -f2- || true)
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

# Capture the current HEAD so the auditor (and cancel) can scope diffs /
# reverts to just the commits this lightweight authored.
start_sha=$(git -C "$repo_root" rev-parse HEAD)

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
branch=main
start_sha=$start_sha
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

nimbus_home="${NIMBUS_HOME:-$(cd "$repo_root" && pwd)}"

if tmux has-session -t "$tmux_session" 2>/dev/null; then
    tmux new-window -t "$tmux_session:" -n "$window_name" -c "$repo_root" -e NIMBUS_HOME="$nimbus_home" "$worker_cmd"
else
    tmux new-session -d -s "$tmux_session" -n "$window_name" -c "$repo_root" -e NIMBUS_HOME="$nimbus_home" "$worker_cmd"
fi

echo "spawned lightweight: $slug"
echo "  branch:     main  (commits go directly to main)"
echo "  start_sha:  $start_sha"
echo "  session_id: $session_id"
echo "  effort:     medium  (sonnet)"
echo "  task:       $(echo "$task" | head -1 | cut -c1-80)$([[ $(echo "$task" | wc -l) -gt 1 ]] && echo ' ...')"
echo
echo "attach with: tmux attach -t $tmux_session"
