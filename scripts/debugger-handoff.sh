#!/usr/bin/env bash
# Called by a debugger to bounce the work back to its paired worker
# with revision requests.
#
# Usage:
#   ./scripts/debugger-handoff.sh "<numbered revisions>"
#
# Must be run inside the pair's worktree (cwd basename nimbus-<slug>).
# Increments review_rounds. If the new rounds count meets or exceeds
# review_cap, transitions pair_state=escalated and state=blocked
# instead — the auditor will see "pair <slug> escalated" on next prompt.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 \"<feedback>\"" >&2
    exit 1
fi

feedback="$*"

worktree="$(git rev-parse --show-toplevel)"
worktree_name="${worktree##*/}"
if [[ "$worktree_name" != nimbus-* ]]; then
    echo "error: not in an nimbus-<slug> worktree" >&2
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
    echo "error: $slug is not a pair" >&2
    exit 1
fi

review_rounds=$(grep '^review_rounds=' "$state_file" | head -1 | cut -d= -f2-)
review_cap=$(grep '^review_cap=' "$state_file" | head -1 | cut -d= -f2-)
new_rounds=$((review_rounds + 1))
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Decide: revision or escalation?
escalate=0
if (( new_rounds >= review_cap )); then
    escalate=1
fi

tmp=$(mktemp)
if (( escalate )); then
    while IFS= read -r line; do
        case "$line" in
            state=*)          echo "state=blocked" ;;
            pair_state=*)     echo "pair_state=escalated" ;;
            updated_at=*)     echo "updated_at=$now" ;;
            review_rounds=*)  echo "review_rounds=$new_rounds" ;;
            blocked_reason=*) echo "blocked_reason=pair exceeded review cap ($new_rounds/$review_cap): $feedback" ;;
            *)                echo "$line" ;;
        esac
    done < "$state_file" > "$tmp"
else
    while IFS= read -r line; do
        case "$line" in
            pair_state=*)    echo "pair_state=awaiting-revision" ;;
            updated_at=*)    echo "updated_at=$now" ;;
            review_rounds=*) echo "review_rounds=$new_rounds" ;;
            *)               echo "$line" ;;
        esac
    done < "$state_file" > "$tmp"
fi
mv "$tmp" "$state_file"

{
    echo "[$now round=$new_rounds/$review_cap] DEBUGGER → WORKER:"
    echo "$feedback"
    echo ""
} >> "$review_log"

if (( escalate )); then
    echo "ESCALATED: review cap $review_cap reached ($new_rounds rounds)."
    echo "The auditor will be notified on its next prompt."
    if [[ -z "${NIMBUS_TEST_MODE:-}" ]]; then
        osascript -e "display notification \"$slug: pair exceeded review cap\" with title \"Nimbus pair escalated\"" 2>/dev/null || true
        "$main_repo/scripts/wake-auditor.sh" "$slug" "escalated" 2>/dev/null || true
    fi
    exit 0
fi

# Otherwise deliver into the worker's tmux window.
prompt="Debugger requests revisions (round $new_rounds/$review_cap):

$feedback

Address the items, commit, and hand off again with:
    ./scripts/worker-handoff.sh \"<one-line summary>\"

The spec at $state_dir/$slug.spec.md is the canonical bar."

tmux_session="nimbus-workers"
if tmux list-windows -t "$tmux_session" -F "#{window_name}" 2>/dev/null | grep -qx "$slug"; then
    buf="__nimbus_$slug"
    printf '%s' "$prompt" | tmux load-buffer -b "$buf" -
    tmux paste-buffer -t "$tmux_session:$slug" -b "$buf" -d -p
    sleep 0.1
    tmux send-keys -t "$tmux_session:$slug" Enter
    echo "delivered to worker $slug; rounds=$new_rounds/$review_cap"
else
    # Worker window gone; queue in mailbox.
    mailbox="$state_dir/$slug.mailbox"
    if [[ -f "$mailbox" ]]; then
        { echo ""; echo "---"; echo ""; } >> "$mailbox"
    fi
    echo "$prompt" >> "$mailbox"
    echo "worker $slug is offline; queued in mailbox. rounds=$new_rounds/$review_cap"
fi
