#!/usr/bin/env bash
# Auditor-only: send revision feedback to a critic, or simply reply
# to it inline. Increments review_rounds; auto-escalates when the
# cap is reached, mirroring debugger-handoff.sh.
#
# Usage:
#   ./scripts/talk-to-critic.sh <slug> "<feedback>"
#
# Used by the auditor after reading a critic's critique to ask for
# revisions ("revisit the empty-state screen too", "the severities
# look off, regrade them"). Pastes into the critic's tmux window via
# the same bracketed-paste + Enter primitive used by talk-to-worker.sh.
# Every round is appended to .auditor-state/<slug>.critique.log so the
# auditor can see what was contested across rounds.

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "usage: $0 <slug> \"<feedback>\"" >&2
    exit 1
fi

slug="$1"
shift
feedback="$*"

repo_root="$(git rev-parse --show-toplevel)"
state_dir="$repo_root/.auditor-state"
state_file="$state_dir/$slug.state"
critique_log="$state_dir/$slug.critique.log"
tmux_session="nimbus-workers"
crit_window="${slug}-crit"

if [[ ! -f "$state_file" ]]; then
    echo "error: no critic $slug" >&2
    exit 1
fi
role=$(grep '^role=' "$state_file" | head -1 | cut -d= -f2-)
if [[ "$role" != "critic" ]]; then
    echo "error: $slug has role=$role, not critic" >&2
    exit 1
fi

review_rounds=$(grep '^review_rounds=' "$state_file" | head -1 | cut -d= -f2-)
review_cap=$(grep '^review_cap=' "$state_file" | head -1 | cut -d= -f2-)
review_rounds="${review_rounds:-0}"
review_cap="${review_cap:-5}"
new_rounds=$((review_rounds + 1))
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Decide: revision or auto-escalation? Same shape as debugger-handoff.
escalate=0
if (( new_rounds >= review_cap )); then
    escalate=1
fi

tmp=$(mktemp)
if (( escalate )); then
    while IFS= read -r line; do
        case "$line" in
            state=*)          echo "state=blocked" ;;
            updated_at=*)     echo "updated_at=$now" ;;
            review_rounds=*)  echo "review_rounds=$new_rounds" ;;
            blocked_reason=*) echo "blocked_reason=critic exceeded review cap ($new_rounds/$review_cap): $feedback" ;;
            *)                echo "$line" ;;
        esac
    done < "$state_file" > "$tmp"
else
    # If the critic was blocked (e.g. waiting on a tooling fix), the
    # auditor's reply is presumed to unblock — same shape as
    # talk-to-worker.sh.
    state=$(grep '^state=' "$state_file" | head -1 | cut -d= -f2-)
    while IFS= read -r line; do
        case "$line" in
            state=*)
                if [[ "$state" == "blocked" ]]; then
                    echo "state=running"
                else
                    echo "$line"
                fi
                ;;
            updated_at=*)     echo "updated_at=$now" ;;
            review_rounds=*)  echo "review_rounds=$new_rounds" ;;
            blocked_reason=*)
                if [[ "$state" == "blocked" ]]; then
                    echo "blocked_reason="
                else
                    echo "$line"
                fi
                ;;
            *)                echo "$line" ;;
        esac
    done < "$state_file" > "$tmp"
fi
mv "$tmp" "$state_file"

{
    echo "[$now round=$new_rounds/$review_cap] AUDITOR → CRITIC:"
    echo "$feedback"
    echo ""
} >> "$critique_log"

if (( escalate )); then
    echo "ESCALATED: review cap $review_cap reached ($new_rounds rounds)."
    echo "The auditor will be notified on its next prompt."
    osascript -e "display notification \"$slug: critic exceeded review cap\" with title \"Nimbus critic escalated\"" 2>/dev/null || true
    "$repo_root/scripts/wake-auditor.sh" "$slug" "escalated" 2>/dev/null || true
    exit 0
fi

# Otherwise deliver into the critic's tmux window.
prompt="Auditor requests revisions (round $new_rounds/$review_cap):

$feedback

Update .auditor-state/$slug.critique.md and re-run:
    ./scripts/critic-done.sh \"<one-line summary>\""

if tmux list-windows -t "$tmux_session" -F "#{window_name}" 2>/dev/null | grep -qx "$crit_window"; then
    buf="__nimbus_${slug}_crit"
    printf '%s' "$prompt" | tmux load-buffer -b "$buf" -
    tmux paste-buffer -t "$tmux_session:$crit_window" -b "$buf" -d -p
    sleep 0.1
    tmux send-keys -t "$tmux_session:$crit_window" Enter
    echo "delivered to critic $slug; rounds=$new_rounds/$review_cap"
else
    # Critic window gone; queue in mailbox so a resume picks it up.
    mailbox="$state_dir/$slug.mailbox"
    if [[ -f "$mailbox" ]]; then
        { echo ""; echo "---"; echo ""; } >> "$mailbox"
    fi
    echo "$prompt" >> "$mailbox"
    echo "critic $slug window is offline; queued in mailbox. rounds=$new_rounds/$review_cap"
fi
