#!/usr/bin/env bash
# Push a wake-up prompt into the auditor's tmux window so it reacts to
# a state change. This is the auditor's sole reactivity mechanism;
# without a push wake-up (or a direct user prompt) the auditor sits idle.
#
# Usage:
#   ./scripts/wake-auditor.sh <slug> <kind>
#
#   <kind> is a short label for what just happened — done, blocked,
#   escalated, etc. Used only for the prompt text; the real signal is
#   the .state file plus the UserPromptSubmit notify hook, which fires
#   when the auditor receives the prompt.
#
# No-op (exit 0) if the auditor tmux session does not exist — the
# state file is still written, and the auditor will pick it up the
# next time it boots.

set -u

if [[ $# -lt 2 ]]; then
    echo "usage: $0 <slug> <kind>" >&2
    exit 1
fi

slug="$1"
kind="$2"
session="nimbus-auditor"

# Silent no-op if tmux is missing or the session is gone.
if ! command -v tmux >/dev/null 2>&1; then
    exit 0
fi
if ! tmux has-session -t "$session" 2>/dev/null; then
    exit 0
fi

# Use bracketed paste + Enter, same convention as talk-to-worker.sh,
# so the input lands as one user prompt rather than racing claude's
# input handler.
buf="__nimbus_audit_wake_${slug}"
printf '%s' "(push wake-up: $slug → $kind)" | tmux load-buffer -b "$buf" -
tmux paste-buffer -t "${session}:0" -b "$buf" -d -p
sleep 0.1
tmux send-keys -t "${session}:0" Enter

exit 0
