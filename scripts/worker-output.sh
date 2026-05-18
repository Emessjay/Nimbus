#!/usr/bin/env bash
# Show recent terminal output from a worker's tmux pane.
#
# Usage:
#   ./scripts/worker-output.sh <slug>          # last 200 lines
#   ./scripts/worker-output.sh <slug> 500      # last <n> lines
#
# Use this to peek at what a running worker is doing without
# attaching to its tmux window (which would steal focus from your
# own terminal). The output is a snapshot of the worker's current
# tmux pane buffer, including any in-progress Claude response.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <slug> [lines]" >&2
    exit 1
fi

slug="$1"
lines="${2:-200}"
tmux_session="nimbus-workers"

if ! command -v tmux >/dev/null 2>&1; then
    echo "error: tmux is not installed" >&2
    exit 1
fi

if ! tmux list-windows -t "$tmux_session" -F "#{window_name}" 2>/dev/null \
     | grep -qx "$slug"; then
    echo "error: no live tmux window for $slug in $tmux_session" >&2
    echo "       the worker's session may have exited; check state with:" >&2
    echo "         ./scripts/worker-status.sh $slug" >&2
    exit 1
fi

tmux capture-pane -t "$tmux_session:$slug" -p -S "-$lines"
