#!/usr/bin/env bash
# Scan .auditor-state for pairs that have been sitting in
# awaiting-review / awaiting-revision longer than the stall threshold,
# and push a wake-up into the auditor's tmux session for each one we
# haven't already pinged about.
#
# Designed to be run on a timer from a background sweeper (see the
# loop started by nimbus-audit in scripts/nimbus-functions.sh). Safe
# to run by hand too.
#
# Rate limiting: a side-file `.auditor-state/.stall-pinged` records
# `slug=updated_at` for each (slug, updated_at) we've already pinged.
# A stalled pair is re-pinged only when its updated_at advances
# (i.e. the pair makes progress) and then it re-stalls.
#
# Env overrides (for tests):
#   NIMBUS_STATE_DIR     — directory containing *.state files.
#                          Defaults to <repo>/.auditor-state.
#   NIMBUS_WAKE_AUDITOR  — path to wake-auditor.sh (or a stub).
#                          Defaults to <repo>/scripts/wake-auditor.sh.

set -u

# Stall threshold: keep in sync with the notify hook
# (.claude/hooks/auditor-worker-notify.sh).
STALL_THRESHOLD_SECONDS=900

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

state_dir="${NIMBUS_STATE_DIR:-$repo_root/.auditor-state}"
wake_auditor="${NIMBUS_WAKE_AUDITOR:-$repo_root/scripts/wake-auditor.sh}"

[[ -d "$state_dir" ]] || exit 0

pinged="$state_dir/.stall-pinged"
new_pinged=$(mktemp "$state_dir/.stall-pinged.XXXXXX")
now_epoch=$(date -u +%s)

shopt -s nullglob
for state_file in "$state_dir"/*.state; do
    slug=""
    state=""
    pair_state=""
    updated_at=""
    while IFS='=' read -r k v; do
        case "$k" in
            slug)       slug="$v" ;;
            state)      state="$v" ;;
            pair_state) pair_state="$v" ;;
            updated_at) updated_at="$v" ;;
        esac
    done < "$state_file"
    [[ -z "$slug" ]] && continue
    [[ "$state" != "running" && "$state" != "blocked" ]] && continue
    [[ "$pair_state" != "awaiting-review" && "$pair_state" != "awaiting-revision" ]] && continue
    [[ -z "$updated_at" ]] && continue

    updated_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$updated_at" "+%s" 2>/dev/null) || continue
    age=$((now_epoch - updated_epoch))
    (( age > STALL_THRESHOLD_SECONDS )) || continue

    # Look up prior ping marker; only ping if updated_at differs.
    prev_pinged=""
    if [[ -f "$pinged" ]]; then
        prev_pinged=$(grep "^${slug}=" "$pinged" 2>/dev/null | head -1 | cut -d= -f2-)
    fi
    if [[ "$prev_pinged" != "$updated_at" ]]; then
        "$wake_auditor" "$slug" stalled >/dev/null 2>&1 || true
    fi
    printf '%s=%s\n' "$slug" "$updated_at" >> "$new_pinged"
done
shopt -u nullglob

mv "$new_pinged" "$pinged"
exit 0
