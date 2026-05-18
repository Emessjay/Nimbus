#!/usr/bin/env bash
# Spawn a worker Claude in a new git worktree.
#
# Usage:
#   ./scripts/spawn-worker.sh [--effort LEVEL] <slug> <task>
#
#   <task> may be either an inline string, or `@path/to/file.md`
#   to load the brief from a file. The file form is useful for
#   structured briefs longer than a comfortable shell argument.
#
#   --effort LEVEL  one of low|medium|high|xhigh|max (default: medium)
#                   Workers default to medium because the auditor's
#                   xhigh budget is reserved for orchestration; bump
#                   to high for tasks that need deep reasoning.
#
# Run by the auditor. Refuses if 5 workers are already active (states
# `running` or `blocked`). Creates ../nimbus-<slug>/ via
# scripts/new-worktree.sh if it does not exist, writes state files
# under .auditor-state/, then boots the worker in a tmux window in the
# shared `nimbus-workers` session.

set -euo pipefail

effort="medium"

# Parse leading --effort flag.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --effort)
            effort="${2:-}"
            shift 2
            ;;
        --effort=*)
            effort="${1#--effort=}"
            shift
            ;;
        -*)
            echo "error: unknown flag $1" >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

case "$effort" in
    low|medium|high|xhigh|max) ;;
    *)
        echo "error: invalid --effort '$effort' (must be low|medium|high|xhigh|max)" >&2
        exit 1
        ;;
esac

if [[ $# -lt 2 ]]; then
    echo "usage: $0 [--effort LEVEL] <slug> <task | @path/to/file>" >&2
    exit 1
fi

slug="$1"
shift
task="$*"

if [[ ! "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "error: slug must be lowercase alphanumeric with dashes, got: $slug" >&2
    exit 1
fi

# Resolve @file briefs into inline text.
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

# Preflight: refuse if main has uncommitted changes. Otherwise the
# eventual merge-worker.sh would have to refuse, leaving the worker
# stranded. Better to fail fast.
if ! git -C "$repo_root" diff --quiet || ! git -C "$repo_root" diff --cached --quiet; then
    echo "error: main worktree has uncommitted changes; commit, stash, or revert before spawning a worker" >&2
    git -C "$repo_root" status --short >&2
    exit 1
fi

# Enforce the 5-worker cap.
active=0
shopt -s nullglob
for state_file in "$state_dir"/*.state; do
    s=$(grep '^state=' "$state_file" | head -1 | cut -d= -f2-)
    if [[ "$s" == "running" || "$s" == "blocked" ]]; then
        active=$((active + 1))
    fi
done
shopt -u nullglob
if [[ "$active" -ge 5 ]]; then
    echo "error: $active workers already active (cap is 5)" >&2
    echo "       merge, cancel, or fail an existing worker before spawning another." >&2
    exit 1
fi

worktree_path="${repo_root%/*}/nimbus-${slug}"
branch="feature/${slug}"

# Refuse if a worker with this slug is already in flight.
if [[ -f "$state_dir/$slug.state" ]]; then
    existing_state=$(grep '^state=' "$state_dir/$slug.state" | head -1 | cut -d= -f2-)
    if [[ "$existing_state" == "running" || "$existing_state" == "blocked" ]]; then
        echo "error: worker '$slug' is already $existing_state" >&2
        echo "       send it a message with talk-to-worker.sh or merge it first." >&2
        exit 1
    fi
fi

# Create the worktree if it does not exist.
if [[ ! -d "$worktree_path" ]]; then
    "$repo_root/scripts/new-worktree.sh" "$slug"
fi

session_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "$task" > "$state_dir/$slug.task"
cat > "$state_dir/$slug.state" <<EOF
slug=$slug
role=worker
state=running
spawned_at=$now
updated_at=$now
worktree_path=$worktree_path
branch=$branch
session_id=$session_id
effort=$effort
pair_mode=solo
summary=
blocked_reason=
EOF

# Make sure any stale mailbox from a previous worker with this slug is gone.
rm -f "$state_dir/$slug.mailbox"

# Boot the worker inside a tmux window. All workers share a single
# detached session named "nimbus-workers"; each worker gets its own
# window named after its slug. The session auto-vanishes when the last
# window closes.
tmux_session="nimbus-workers"
worker_cmd="$repo_root/scripts/nimbus-worker.sh $slug"

# Kill any stale window from a previous worker with this slug.
if tmux list-windows -t "$tmux_session" -F "#{window_name}" 2>/dev/null | grep -qx "$slug"; then
    tmux kill-window -t "$tmux_session:$slug" 2>/dev/null || true
fi

nimbus_home="${NIMBUS_HOME:-$(cd "$repo_root" && pwd)}"

if tmux has-session -t "$tmux_session" 2>/dev/null; then
    tmux new-window -t "$tmux_session:" -n "$slug" -c "$worktree_path" -e NIMBUS_HOME="$nimbus_home" "$worker_cmd"
else
    tmux new-session -d -s "$tmux_session" -n "$slug" -c "$worktree_path" -e NIMBUS_HOME="$nimbus_home" "$worker_cmd"
fi

spec_file="$state_dir/$slug.spec.md"
spec_status="none (optional for solo workers; required for pairs)"
[[ -f "$spec_file" ]] && spec_status="$spec_file"

echo "spawned worker: $slug"
echo "  worktree:   $worktree_path"
echo "  branch:     $branch"
echo "  session_id: $session_id"
echo "  effort:     $effort"
echo "  spec:       $spec_status"
echo "  task:       $(echo "$task" | head -1 | cut -c1-80)$([[ $(echo "$task" | wc -l) -gt 1 ]] && echo ' ...')"
echo
echo "attach with: tmux attach -t $tmux_session"
