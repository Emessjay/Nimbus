#!/usr/bin/env bash
# Auditor-only: send a message into the debugger's tmux window.
#
# Usage:
#   ./scripts/talk-to-debugger.sh <slug> "<message>"
#
# Used when the auditor wants to direct the debugger without going
# through the worker (e.g. "stop nitpicking and approve" or "the spec
# is wrong, here's the new spec, re-review"). Delivery semantics mirror
# talk-to-worker.sh; the target window is <slug>-dbg.

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
tmux_session="nimbus-workers"
dbg_window="${slug}-dbg"

if [[ ! -f "$state_file" ]]; then
    echo "error: no pair $slug" >&2
    exit 1
fi
pair_mode=$(grep '^pair_mode=' "$state_file" | head -1 | cut -d= -f2-)
if [[ "$pair_mode" != "paired" ]]; then
    echo "error: $slug is not a pair (pair_mode=$pair_mode)" >&2
    exit 1
fi

window_alive=0
if command -v tmux >/dev/null 2>&1 \
   && tmux list-windows -t "$tmux_session" -F "#{window_name}" 2>/dev/null \
        | grep -qx "$dbg_window"; then
    window_alive=1
fi

if [[ "$window_alive" -eq 1 ]]; then
    buf="__nimbus_${slug}_dbg"
    printf '%s' "$message" | tmux load-buffer -b "$buf" -
    tmux paste-buffer -t "$tmux_session:$dbg_window" -b "$buf" -d -p
    sleep 0.1
    tmux send-keys -t "$tmux_session:$dbg_window" Enter
    echo "delivered to debugger ($dbg_window)"
else
    echo "error: debugger window $dbg_window is not alive; mailbox fallback is worker-side only" >&2
    echo "       use cancel-worker.sh $slug to abort, or talk to the worker instead." >&2
    exit 1
fi
