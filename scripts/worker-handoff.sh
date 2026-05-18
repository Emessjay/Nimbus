#!/usr/bin/env bash
# Called by a paired worker to hand the work off to its debugger for
# review.
#
# Usage:
#   ./scripts/worker-handoff.sh "<one-line summary of what you just committed>"
#
# Must be run inside the worker's worktree (cwd basename nimbus-<slug>)
# AND the .state file must have pair_mode=paired. The worker must have
# at least one commit ahead of main since the last handoff (or since
# spawn, if first handoff).

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 \"<summary>\"" >&2
    exit 1
fi

summary="$*"

worktree="$(git rev-parse --show-toplevel)"
worktree_name="${worktree##*/}"
if [[ "$worktree_name" != nimbus-* ]]; then
    echo "error: not in an nimbus-<slug> worktree (cwd is $worktree)" >&2
    exit 1
fi
slug="${worktree_name#nimbus-}"

main_repo=$(git worktree list --porcelain | awk '/^worktree / { print $2; exit }')
state_dir="$main_repo/.auditor-state"
state_file="$state_dir/$slug.state"
review_log="$state_dir/$slug.review.log"

if [[ ! -f "$state_file" ]]; then
    echo "error: no state for $slug" >&2
    exit 1
fi

pair_mode=$(grep '^pair_mode=' "$state_file" | head -1 | cut -d= -f2-)
if [[ "$pair_mode" != "paired" ]]; then
    echo "error: $slug is not a pair (pair_mode=$pair_mode); use worker-done.sh instead" >&2
    exit 1
fi

ahead=$(git rev-list --count main..HEAD 2>/dev/null || echo "0")
if [[ "$ahead" -eq 0 ]]; then
    echo "error: no commits ahead of main on $(git branch --show-current)" >&2
    echo "       commit your work before handing off." >&2
    exit 1
fi

review_rounds=$(grep '^review_rounds=' "$state_file" | head -1 | cut -d= -f2-)
review_cap=$(grep '^review_cap=' "$state_file" | head -1 | cut -d= -f2-)

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp)
while IFS= read -r line; do
    case "$line" in
        pair_state=*) echo "pair_state=awaiting-review" ;;
        updated_at=*) echo "updated_at=$now" ;;
        *)            echo "$line" ;;
    esac
done < "$state_file" > "$tmp"
mv "$tmp" "$state_file"

# Append to the review log so the auditor can sample contested points.
{
    echo "[$now round=${review_rounds:-0}/${review_cap:-?}] WORKER → DEBUGGER:"
    echo "$summary"
    echo ""
} >> "$review_log"

# Deliver the handoff prompt into the debugger's tmux window.
diff_range="main..HEAD"
prompt="Worker has handed off for review (round ${review_rounds:-0}/${review_cap:-?}).

Summary: $summary

Inspect with:
    git -C $worktree diff $diff_range
    git -C $worktree log --oneline $diff_range

Review against the spec at:
    $state_dir/$slug.spec.md

Then call one of:
    ./scripts/debugger-handoff.sh \"<numbered revisions>\"
    ./scripts/debugger-approve.sh \"<summary>\"
    ./scripts/debugger-blocked.sh \"<reason — auditor needs to decide>\""

tmux_session="nimbus-workers"
dbg_window="${slug}-dbg"
if tmux list-windows -t "$tmux_session" -F "#{window_name}" 2>/dev/null | grep -qx "$dbg_window"; then
    buf="__nimbus_${slug}_dbg"
    printf '%s' "$prompt" | tmux load-buffer -b "$buf" -
    tmux paste-buffer -t "$tmux_session:$dbg_window" -b "$buf" -d -p
    sleep 0.1
    tmux send-keys -t "$tmux_session:$dbg_window" Enter
    echo "handed off to debugger ($dbg_window); rounds=${review_rounds:-0}/${review_cap:-?}"
else
    echo "error: debugger window $dbg_window is not alive; surfacing to auditor instead" >&2
    # Soft fallback: set blocked so the auditor can investigate.
    tmp=$(mktemp)
    while IFS= read -r line; do
        case "$line" in
            state=*)          echo "state=blocked" ;;
            updated_at=*)     echo "updated_at=$now" ;;
            blocked_reason=*) echo "blocked_reason=debugger window missing; cannot hand off" ;;
            *)                echo "$line" ;;
        esac
    done < "$state_file" > "$tmp"
    mv "$tmp" "$state_file"
    exit 1
fi
