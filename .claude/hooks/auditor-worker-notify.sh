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

# Stall threshold: pairs in awaiting-review / awaiting-revision longer
# than this (seconds since updated_at) are reported as stalled. 15 min
# is long enough to swallow a slow debugger boot but short enough that
# a truly hung pair is surfaced before the auditor session times out.
STALL_THRESHOLD_SECONDS=900

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
now_epoch=$(date -u +%s)

shopt -s nullglob
for state_file in "$state_dir"/*.state; do
    slug=""
    state=""
    summary=""
    blocked_reason=""
    role="worker"
    pair_state=""
    updated_at=""
    while IFS='=' read -r k v; do
        case "$k" in
            slug)           slug="$v" ;;
            state)          state="$v" ;;
            summary)        summary="$v" ;;
            blocked_reason) blocked_reason="$v" ;;
            role)           role="$v" ;;
            pair_state)     pair_state="$v" ;;
            updated_at)     updated_at="$v" ;;
        esac
    done < "$state_file"
    [[ -z "$slug" || -z "$state" ]] && continue

    # Parse previous sentinel line. Format: slug=state|pair_state|stalled_at
    # where stalled_at is the updated_at at which we last reported a
    # stall for this slug (empty if not currently reported). Missing
    # trailing fields default to empty, so older sentinels still parse.
    prev_state=""
    prev_pair=""
    prev_stalled_at=""
    if [[ -f "$sentinel" ]]; then
        prev_line=$(grep "^${slug}=" "$sentinel" 2>/dev/null | head -1 | cut -d= -f2-)
        if [[ -n "$prev_line" ]]; then
            IFS='|' read -r prev_state prev_pair prev_stalled_at <<<"$prev_line"
        fi
    fi

    # Stall detection: pair sitting in awaiting-review / awaiting-revision
    # longer than the threshold. One-shot — re-report only when
    # updated_at advances (progress) and then the pair stalls again.
    new_stalled_at=""
    if [[ "$state" == "running" || "$state" == "blocked" ]] \
       && [[ "$pair_state" == "awaiting-review" || "$pair_state" == "awaiting-revision" ]] \
       && [[ -n "$updated_at" ]]; then
        if updated_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$updated_at" "+%s" 2>/dev/null); then
            age=$((now_epoch - updated_epoch))
            if (( age > STALL_THRESHOLD_SECONDS )); then
                new_stalled_at="$updated_at"
                if [[ "$prev_stalled_at" != "$updated_at" ]]; then
                    age_min=$((age / 60))
                    case "$pair_state" in
                        awaiting-review)
                            printf 'pair %s stalled: awaiting-review for %dm (debugger has not responded)\n' "$slug" "$age_min" ;;
                        awaiting-revision)
                            printf 'pair %s stalled: awaiting-revision for %dm (worker has not picked up revisions)\n' "$slug" "$age_min" ;;
                    esac
                fi
            fi
        fi
    fi

    # Sentinel tracks state, pair_state, and stalled_at so that
    # transitions (awaiting-review → escalated) and stalls each fire
    # exactly once.
    printf '%s=%s|%s|%s\n' "$slug" "$state" "$pair_state" "$new_stalled_at" >> "$new_sentinel"

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
