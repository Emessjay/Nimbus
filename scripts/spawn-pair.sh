#!/usr/bin/env bash
# Spawn a worker + debugger pair in a new git worktree.
#
# Usage:
#   ./scripts/spawn-pair.sh [--effort LEVEL] [--review-cap N] <slug> <task | @path/to/file>
#
# Like spawn-worker.sh but also boots a debugger sibling. The debugger
# lives in the same worktree (one tmux window each: <slug> and
# <slug>-dbg). Worker writes code; debugger reads diffs, runs tests,
# and ping-pongs revision feedback. The two together count as one slot
# against the 5-worker cap.
#
# REQUIRES the auditor to have written .auditor-state/<slug>.spec.md
# before calling. The spec is the debugger's canonical reference; no
# spec, no spawn.

set -euo pipefail

effort="medium"
review_cap=5

while [[ $# -gt 0 ]]; do
    case "$1" in
        --effort)      effort="${2:-}"; shift 2 ;;
        --effort=*)    effort="${1#--effort=}"; shift ;;
        --review-cap)  review_cap="${2:-}"; shift 2 ;;
        --review-cap=*) review_cap="${1#--review-cap=}"; shift ;;
        -*)            echo "error: unknown flag $1" >&2; exit 1 ;;
        *)             break ;;
    esac
done

case "$effort" in
    low|medium|high|xhigh|max) ;;
    *) echo "error: invalid --effort '$effort'" >&2; exit 1 ;;
esac

if ! [[ "$review_cap" =~ ^[0-9]+$ ]] || (( review_cap < 1 )); then
    echo "error: --review-cap must be a positive integer, got '$review_cap'" >&2
    exit 1
fi

if [[ $# -lt 2 ]]; then
    echo "usage: $0 [--effort LEVEL] [--review-cap N] <slug> <task | @path/to/file>" >&2
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

# REQUIRE the spec file. The debugger reviews against the spec; without
# one, it would have to invent its own bar.
spec_file="$state_dir/$slug.spec.md"
if [[ ! -f "$spec_file" ]]; then
    cat >&2 <<EOF
error: pairs require an auditor-written spec at:
  $spec_file

Write the spec first (see AUDITOR.md for the template — Goal,
Acceptance criteria, In scope, Out of scope, Constraints, Verification),
then re-run spawn-pair.sh.
EOF
    exit 1
fi

# Preflight: main worktree must be clean (eventual merge requires it).
if ! git -C "$repo_root" diff --quiet || ! git -C "$repo_root" diff --cached --quiet; then
    echo "error: main worktree has uncommitted changes; commit, stash, or revert before spawning a pair" >&2
    git -C "$repo_root" status --short >&2
    exit 1
fi

# 5-worker cap (pair counts as one slot).
active=0
shopt -s nullglob
for sf in "$state_dir"/*.state; do
    s=$(grep '^state=' "$sf" | head -1 | cut -d= -f2-)
    if [[ "$s" == "running" || "$s" == "blocked" ]]; then
        active=$((active + 1))
    fi
done
shopt -u nullglob
if [[ "$active" -ge 5 ]]; then
    echo "error: $active workers already active (cap is 5)" >&2
    exit 1
fi

# Refuse if a pair with this slug is already in flight.
if [[ -f "$state_dir/$slug.state" ]]; then
    existing_state=$(grep '^state=' "$state_dir/$slug.state" | head -1 | cut -d= -f2-)
    if [[ "$existing_state" == "running" || "$existing_state" == "blocked" ]]; then
        echo "error: '$slug' is already $existing_state" >&2
        exit 1
    fi
fi

worktree_path="${repo_root%/*}/nimbus-${slug}"
branch="feature/${slug}"

if [[ ! -d "$worktree_path" ]]; then
    "$repo_root/scripts/new-worktree.sh" "$slug"
fi

session_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
debugger_session_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
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
debugger_session_id=$debugger_session_id
effort=$effort
pair_mode=paired
pair_state=running
review_rounds=0
review_cap=$review_cap
summary=
blocked_reason=
EOF

rm -f "$state_dir/$slug.mailbox"
# Initialize the review log; debugger and worker handoffs append.
: > "$state_dir/$slug.review.log"

tmux_session="nimbus-workers"
worker_cmd="$repo_root/scripts/nimbus-worker.sh --role worker $slug"
debugger_cmd="$repo_root/scripts/nimbus-worker.sh --role debugger $slug"

# Kill stale windows.
for w in "$slug" "${slug}-dbg"; do
    if tmux list-windows -t "$tmux_session" -F "#{window_name}" 2>/dev/null | grep -qx "$w"; then
        tmux kill-window -t "$tmux_session:$w" 2>/dev/null || true
    fi
done

if tmux has-session -t "$tmux_session" 2>/dev/null; then
    tmux new-window -t "$tmux_session:" -n "$slug" -c "$worktree_path" "$worker_cmd"
else
    tmux new-session -d -s "$tmux_session" -n "$slug" -c "$worktree_path" "$worker_cmd"
fi
tmux new-window -t "$tmux_session:" -n "${slug}-dbg" -c "$worktree_path" "$debugger_cmd"

echo "spawned pair: $slug"
echo "  worktree:           $worktree_path"
echo "  branch:             $branch"
echo "  worker session:     $session_id"
echo "  debugger session:   $debugger_session_id"
echo "  effort:             $effort   review cap: $review_cap"
echo "  spec:               $spec_file"
echo "  task:               $(echo "$task" | head -1 | cut -c1-80)$([[ $(echo "$task" | wc -l) -gt 1 ]] && echo ' ...')"
echo
echo "attach with: tmux attach -t $tmux_session   (windows: $slug, ${slug}-dbg)"
