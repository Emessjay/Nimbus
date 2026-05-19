#!/usr/bin/env bash
# Scan .auditor-state for two failure modes that the lifecycle scripts
# can't report on their own, and push a wake-up into the auditor's tmux
# session for each one we haven't already pinged about:
#
#   1. Pairs sitting in awaiting-review / awaiting-revision longer than
#      the stall threshold (debugger / worker isn't responding).
#   2. Solo agents (lightweight, critic, solo worker) whose tmux window
#      has vanished while their state file still says `running` — i.e.
#      the agent process died without calling its done or blocked
#      script. Paired workers are excluded: after handoff their window
#      legitimately exits, and the pair stall check above covers a
#      stuck debugger.
#
# Designed to be run on a timer from a background sweeper (see the
# loop started by nimbus-audit in scripts/nimbus-functions.sh). Safe
# to run by hand too.
#
# Rate limiting: side-files in $state_dir record (slug, key) pairs we
# have already pinged about. `.stall-pinged` keys on `updated_at` so a
# pair is re-pinged when it makes progress and then re-stalls.
# `.dead-pinged` keys on `spawned_at` so a dead solo agent is pinged
# exactly once per spawn — a respawn under the same slug rewrites
# `spawned_at` and is eligible to ping again.
#
# Env overrides (for tests):
#   NIMBUS_STATE_DIR     — directory containing *.state files.
#                          Defaults to <repo>/.auditor-state.
#   NIMBUS_WAKE_AUDITOR  — path to wake-auditor.sh (or a stub).
#                          Defaults to <repo>/scripts/wake-auditor.sh.
#   NIMBUS_TMUX_WINDOWS  — newline-separated list of live window names
#                          to use instead of querying tmux. Lets tests
#                          assert dead-agent detection without spinning
#                          up a real tmux session.

set -u

# Stall threshold: keep in sync with the notify hook
# (.claude/hooks/auditor-worker-notify.sh).
STALL_THRESHOLD_SECONDS=900

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

state_dir="${NIMBUS_STATE_DIR:-$repo_root/.auditor-state}"
wake_auditor="${NIMBUS_WAKE_AUDITOR:-$repo_root/scripts/wake-auditor.sh}"

[[ -d "$state_dir" ]] || exit 0

stall_pinged="$state_dir/.stall-pinged"
dead_pinged="$state_dir/.dead-pinged"
new_stall_pinged=$(mktemp "$state_dir/.stall-pinged.XXXXXX")
new_dead_pinged=$(mktemp "$state_dir/.dead-pinged.XXXXXX")
now_epoch=$(date -u +%s)

# Snapshot of live tmux windows in the workers session, one per line.
# Empty string is a valid value (no session / no windows) — treat every
# `running` solo agent as dead in that case. Tests override via
# NIMBUS_TMUX_WINDOWS to avoid needing a real tmux.
if [[ -n "${NIMBUS_TMUX_WINDOWS+x}" ]]; then
    live_windows="$NIMBUS_TMUX_WINDOWS"
elif command -v tmux >/dev/null 2>&1; then
    live_windows=$(tmux list-windows -t nimbus-workers -F "#{window_name}" 2>/dev/null || true)
else
    live_windows=""
fi

window_is_live() {
    local target="$1"
    [[ -z "$live_windows" ]] && return 1
    printf '%s\n' "$live_windows" | grep -qx "$target"
}

solo_window_name() {
    local role="$1" pair_mode="$2" slug="$3"
    case "$role" in
        lightweight) printf '%s-light' "$slug"; return 0 ;;
        critic)      printf '%s-crit'  "$slug"; return 0 ;;
        worker)
            # Paired workers are handled by the pair stall check;
            # their window legitimately exits after handoff.
            if [[ "$pair_mode" == "solo" || -z "$pair_mode" ]]; then
                printf '%s' "$slug"
                return 0
            fi
            ;;
    esac
    return 1
}

shopt -s nullglob
for state_file in "$state_dir"/*.state; do
    slug=""
    role=""
    state=""
    pair_state=""
    pair_mode=""
    spawned_at=""
    updated_at=""
    while IFS='=' read -r k v; do
        case "$k" in
            slug)       slug="$v" ;;
            role)       role="$v" ;;
            state)      state="$v" ;;
            pair_state) pair_state="$v" ;;
            pair_mode)  pair_mode="$v" ;;
            spawned_at) spawned_at="$v" ;;
            updated_at) updated_at="$v" ;;
        esac
    done < "$state_file"
    [[ -z "$slug" ]] && continue

    # --- 1. Pair stall check ------------------------------------------
    if [[ ( "$state" == "running" || "$state" == "blocked" ) \
          && ( "$pair_state" == "awaiting-review" || "$pair_state" == "awaiting-revision" ) \
          && -n "$updated_at" ]]; then
        updated_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$updated_at" "+%s" 2>/dev/null) || updated_epoch=""
        if [[ -n "$updated_epoch" ]] && (( now_epoch - updated_epoch > STALL_THRESHOLD_SECONDS )); then
            prev=""
            if [[ -f "$stall_pinged" ]]; then
                prev=$(grep "^${slug}=" "$stall_pinged" 2>/dev/null | head -1 | cut -d= -f2-)
            fi
            if [[ "$prev" != "$updated_at" ]]; then
                "$wake_auditor" "$slug" stalled >/dev/null 2>&1 || true
            fi
            printf '%s=%s\n' "$slug" "$updated_at" >> "$new_stall_pinged"
        fi
    fi

    # --- 2. Silent-death check ----------------------------------------
    # Only solo agents: their tmux window should be alive for the whole
    # lifetime of state=running. Paired workers are excluded because
    # their window exits after handoff.
    if [[ "$state" == "running" ]]; then
        if window_name=$(solo_window_name "$role" "$pair_mode" "$slug"); then
            if ! window_is_live "$window_name"; then
                prev=""
                if [[ -f "$dead_pinged" ]]; then
                    prev=$(grep "^${slug}=" "$dead_pinged" 2>/dev/null | head -1 | cut -d= -f2-)
                fi
                if [[ "$prev" != "$spawned_at" ]]; then
                    "$wake_auditor" "$slug" dead >/dev/null 2>&1 || true
                fi
                printf '%s=%s\n' "$slug" "$spawned_at" >> "$new_dead_pinged"
            fi
        fi
    fi
done
shopt -u nullglob

mv "$new_stall_pinged" "$stall_pinged"
mv "$new_dead_pinged"  "$dead_pinged"
exit 0
