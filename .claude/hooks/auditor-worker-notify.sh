#!/usr/bin/env bash
# UserPromptSubmit hook: surface worker state transitions to the
# auditor inline, so the auditor learns about done/blocked/cancelled
# workers without having to poll `list-workers.sh`.
#
# First arg is the project name (default "nimbus"); the hook reads
# <PROJECT_UPPER>_ROLE from the environment.
#
# Scope: only runs when the project's role env var equals "auditor".
# Worker sessions exit silently so they don't see their own state
# changes.
#
# Mechanism: reads every .auditor-state/*.state file (key=value format
# written by spawn-worker.sh / worker-done.sh / worker-blocked.sh /
# cancel-worker.sh), compares each slug's current state to the
# sentinel at .auditor-state/.notify-seen, and emits one line per
# transition into a {done,blocked,cancelled} state. Plain stdout on
# exit 0 is injected as additional context for the next turn (see
# https://code.claude.com/docs/en/hooks — UserPromptSubmit "Plain text
# stdout: any non-JSON text written to stdout is added as context").
#
# Sentinel ownership: this hook is the only writer of .notify-seen.
# Implementation note: stays bash-3 compatible (macOS default) — no
# associative arrays.

set -u

project="${1:-nimbus}"
role_var="$(printf '%s' "$project" | tr '[:lower:]' '[:upper:]')_ROLE"

if [[ "${!role_var:-}" != "auditor" ]]; then
    exit 0
fi

# Resolve the project root from the hook input JSON (`cwd` field).
repo_root=""
if input=$(cat); then
    repo_root=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("cwd", ""))
except Exception:
    pass
' 2>/dev/null || true)
fi
if [[ -z "$repo_root" || ! -d "$repo_root/.auditor-state" ]]; then
    exit 0
fi

state_dir="$repo_root/.auditor-state"
sentinel="$state_dir/.notify-seen"
new_sentinel=$(mktemp "$state_dir/.notify-seen.XXXXXX")

shopt -s nullglob
for state_file in "$state_dir"/*.state; do
    slug=""
    state=""
    summary=""
    blocked_reason=""
    role="worker"
    pair_state=""
    while IFS='=' read -r k v; do
        case "$k" in
            slug)           slug="$v" ;;
            state)          state="$v" ;;
            summary)        summary="$v" ;;
            blocked_reason) blocked_reason="$v" ;;
            role)           role="$v" ;;
            pair_state)     pair_state="$v" ;;
        esac
    done < "$state_file"
    [[ -z "$slug" || -z "$state" ]] && continue

    # Sentinel tracks both state and pair_state so an `awaiting-review`
    # → `escalated` transition is reported even when the outer state
    # stayed `running` for a moment.
    printf '%s=%s|%s\n' "$slug" "$state" "$pair_state" >> "$new_sentinel"

    prev_line=""
    prev_state=""
    prev_pair=""
    if [[ -f "$sentinel" ]]; then
        prev_line=$(grep "^${slug}=" "$sentinel" 2>/dev/null | head -1 | cut -d= -f2-)
        prev_state="${prev_line%%|*}"
        prev_pair="${prev_line#*|}"
    fi
    if [[ "$state" == "$prev_state" && "$pair_state" == "$prev_pair" ]]; then
        continue
    fi

    label="$role"
    [[ -z "$label" || "$label" == "worker" ]] && label="worker"

    # Pair-specific transitions take precedence over the generic state.
    if [[ "$pair_state" == "escalated" && "$prev_pair" != "escalated" ]]; then
        printf 'pair %s escalated: %s\n' "$slug" "${blocked_reason:-(no reason)}"
        continue
    fi

    case "$state" in
        done)      printf '%s %s done: %s\n' "$label" "$slug" "${summary:-(no summary)}" ;;
        blocked)   printf '%s %s blocked: %s\n' "$label" "$slug" "${blocked_reason:-(no reason)}" ;;
        cancelled) printf '%s %s cancelled\n' "$label" "$slug" ;;
        # running / merged / orphaned: not reported here.
    esac
done
shopt -u nullglob

mv "$new_sentinel" "$sentinel"
exit 0
