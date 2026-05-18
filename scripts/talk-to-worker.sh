#!/usr/bin/env bash
# Send a message to a worker.
#
# Usage:
#   ./scripts/talk-to-worker.sh <slug> "<message>"
#
# Delivery model:
#   - If the worker's tmux window is alive, inject the message into its
#     stdin via `tmux send-keys` (bracketed paste for multi-line). The
#     worker sees it as the next user prompt — no focus is taken.
#   - If the window is gone (the worker's claude session has exited),
#     queue the message in .auditor-state/<slug>.mailbox. The auditor
#     should then run `nimbus-worker-resume <slug>` to bring the
#     worker back; nimbus-worker-resume prepends the queued mailbox
#     content to the next prompt.
#   - If the worker's state was `blocked`, flip it back to `running`
#     (the auditor's reply is presumed to unblock).

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "usage: $0 <slug> \"<message>\"" >&2
    exit 1
fi

slug="$1"
shift
message="$*"

repo_root="$(git rev-parse --show-toplevel)"
state_dir="$repo_root/.auditor-state"
state_file="$state_dir/$slug.state"
mailbox="$state_dir/$slug.mailbox"
tmux_session="nimbus-workers"

if [[ ! -f "$state_file" ]]; then
    echo "error: no worker $slug" >&2
    exit 1
fi

# Detect whether the worker's tmux window is alive.
window_alive=0
if command -v tmux >/dev/null 2>&1 \
   && tmux list-windows -t "$tmux_session" -F "#{window_name}" 2>/dev/null \
        | grep -qx "$slug"; then
    window_alive=1
fi

if [[ "$window_alive" -eq 1 ]]; then
    # Deliver via tmux. Use a tmux buffer + bracketed paste so multi-line
    # messages arrive as a single user prompt rather than N separate
    # submissions; trailing Enter submits.
    buf="__nimbus_$slug"
    printf '%s' "$message" | tmux load-buffer -b "$buf" -
    tmux paste-buffer -t "$tmux_session:$slug" -b "$buf" -d -p
    # Small settle delay so the paste fully lands before Enter.
    sleep 0.1
    tmux send-keys -t "$tmux_session:$slug" Enter
    delivery="tmux send-keys → $tmux_session:$slug"
else
    # Window is gone; queue for the next resume.
    if [[ -f "$mailbox" ]]; then
        {
            echo ""
            echo "---"
            echo ""
        } >> "$mailbox"
    fi
    echo "$message" >> "$mailbox"
    delivery="mailbox (worker session is offline)"
fi

# If the worker was blocked, the auditor's reply unblocks.
state=$(grep '^state=' "$state_file" | head -1 | cut -d= -f2-)
if [[ "$state" == "blocked" ]]; then
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    tmp=$(mktemp)
    while IFS= read -r line; do
        case "$line" in
            state=*)          echo "state=running" ;;
            updated_at=*)     echo "updated_at=$now" ;;
            blocked_reason=*) echo "blocked_reason=" ;;
            *)                echo "$line" ;;
        esac
    done < "$state_file" > "$tmp"
    mv "$tmp" "$state_file"
fi

echo "delivered to $slug via $delivery"
if [[ "$window_alive" -eq 0 ]]; then
    echo "  run: nimbus-worker-resume $slug"
    echo "  to bring the worker back and pick up queued mailbox content."
fi
