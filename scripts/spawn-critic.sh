#!/usr/bin/env bash
# Spawn a critic Claude in the home repo's main checkout.
#
# Usage:
#   ./scripts/spawn-critic.sh [--effort LEVEL] <slug> <task | @path/to/file>
#
#   <task> may be either an inline string, or `@path/to/file.md`
#   to load the brief from a file.
#
#   --effort LEVEL  one of low|medium|high|xhigh|max (default: medium)
#
# Run by the auditor after a feature with user-visible UI has been
# merged. The critic does not edit code, does not read source, and
# operates in the main checkout — no worktree, no branch switch.
#
# Cap: 1 concurrent critic. Independent of the 5-worker cap and the
# 1-lightweight cap.

set -euo pipefail

effort="medium"

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

# Cap: at most one critic active at a time. Independent of the
# 5-worker and 1-lightweight caps.
shopt -s nullglob
for sf in "$state_dir"/*.state; do
    # Skip terminal-state files first — they're noise for this cap
    # check AND they predate fields like `role=` in legacy projects,
    # so reading role would trip pipefail. `|| true` is belt-and-braces
    # on the state lookup itself for the same reason.
    s=$(grep '^state=' "$sf" | head -1 | cut -d= -f2- || true)
    case "$s" in
        running|blocked) ;;
        *) continue ;;
    esac
    role=$(grep '^role=' "$sf" | head -1 | cut -d= -f2- || true)
    if [[ "$role" == "critic" ]]; then
        existing=$(grep '^slug=' "$sf" | head -1 | cut -d= -f2- || true)
        echo "error: critic '$existing' is already $s (cap is 1)" >&2
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

session_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Screenshots directory: critic-no-code.sh permits writes here, and
# critic-no-source-read.sh permits reads here. Create it up-front so
# the critic doesn't need to mkdir on first capture.
screenshots_dir="$state_dir/$slug.screenshots"
mkdir -p "$screenshots_dir"

echo "$task" > "$state_dir/$slug.task"
cat > "$state_dir/$slug.state" <<EOF
slug=$slug
role=critic
state=running
spawned_at=$now
updated_at=$now
worktree_path=$repo_root
session_id=$session_id
effort=$effort
pair_mode=solo
review_rounds=0
review_cap=5
summary=
blocked_reason=
EOF

rm -f "$state_dir/$slug.mailbox"
# Initialize the critique log; talk-to-critic.sh appends each round.
: > "$state_dir/$slug.critique.log"

tmux_session="nimbus-workers"
window_name="${slug}-crit"

nimbus_home="${NIMBUS_HOME:-$(cd "$repo_root" && pwd)}"
if [[ ! -x "$nimbus_home/scripts/nimbus-worker.sh" ]]; then
    echo "error: nimbus-worker.sh missing or not executable at $nimbus_home/scripts/nimbus-worker.sh" >&2
    echo "       check that NIMBUS_HOME points at a Nimbus checkout." >&2
    exit 1
fi
critic_cmd="$nimbus_home/scripts/nimbus-worker.sh --role critic $slug"

# Kill any stale window with this name.
if tmux list-windows -t "$tmux_session" -F "#{window_name}" 2>/dev/null | grep -qx "$window_name"; then
    tmux kill-window -t "$tmux_session:$window_name" 2>/dev/null || true
fi

if tmux has-session -t "$tmux_session" 2>/dev/null; then
    tmux new-window -t "$tmux_session:" -n "$window_name" -c "$repo_root" -e NIMBUS_HOME="$nimbus_home" "$critic_cmd"
else
    tmux new-session -d -s "$tmux_session" -n "$window_name" -c "$repo_root" -e NIMBUS_HOME="$nimbus_home" "$critic_cmd"
fi

echo "spawned critic: $slug"
echo "  checkout:    $repo_root  (main checkout; no branch switch)"
echo "  screenshots: $screenshots_dir"
echo "  session_id:  $session_id"
echo "  effort:      $effort"
echo "  task:        $(echo "$task" | head -1 | cut -c1-80)$([[ $(echo "$task" | wc -l) -gt 1 ]] && echo ' ...')"
echo
echo "attach with: tmux attach -t $tmux_session"
