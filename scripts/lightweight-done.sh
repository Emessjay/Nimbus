#!/usr/bin/env bash
# Called by a lightweight to mark itself complete.
#
# Usage:
#   ./scripts/lightweight-done.sh "<one-line summary>"
#
# Lightweights commit directly to `main` (no branch). Refuses if no
# commits exist between the recorded start_sha and HEAD — catches the
# common mistake of marking done before committing. There is no
# auto-integration step: HEAD is already on main by definition.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 \"<summary>\"" >&2
    exit 1
fi

summary="$*"

branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$branch" != "main" ]]; then
    echo "error: HEAD is on '$branch', expected 'main'" >&2
    echo "       lightweights commit directly to main; aborting." >&2
    exit 1
fi

main_repo=$(git rev-parse --show-toplevel)
state_dir="$main_repo/.auditor-state"

# nimbus-worker.sh exports NIMBUS_WORKER_SLUG at boot; prefer it as the
# canonical source of truth. Fall back to scanning state files for the
# active lightweight (cap 1) for self-tests or unusual contexts.
slug="${NIMBUS_WORKER_SLUG:-}"
if [[ -z "$slug" ]]; then
    shopt -s nullglob
    for sf in "$state_dir"/*.state; do
        s=$(grep '^state=' "$sf" | head -1 | cut -d= -f2- || true)
        case "$s" in
            running|blocked) ;;
            *) continue ;;
        esac
        role=$(grep '^role=' "$sf" | head -1 | cut -d= -f2- || true)
        if [[ "$role" == "lightweight" ]]; then
            slug=$(grep '^slug=' "$sf" | head -1 | cut -d= -f2- || true)
            break
        fi
    done
    shopt -u nullglob
fi

if [[ -z "$slug" ]]; then
    echo "error: could not determine lightweight slug (no active lightweight state file)" >&2
    exit 1
fi

state_file="$state_dir/$slug.state"

if [[ ! -f "$state_file" ]]; then
    echo "error: no state file at $state_file" >&2
    exit 1
fi

role=$(grep '^role=' "$state_file" | head -1 | cut -d= -f2- || true)
if [[ "$role" != "lightweight" ]]; then
    echo "error: state file says role=${role:-<missing>}, expected lightweight" >&2
    exit 1
fi

start_sha=$(grep '^start_sha=' "$state_file" | head -1 | cut -d= -f2- || true)
if [[ -z "$start_sha" ]]; then
    echo "error: no start_sha recorded in state file — cannot determine commit range" >&2
    echo "       (state file pre-dates lightweight-no-branch refactor; cancel and respawn.)" >&2
    exit 1
fi

ahead=$(git rev-list --count "$start_sha..HEAD" 2>/dev/null || echo "0")
if [[ "$ahead" -eq 0 ]]; then
    echo "error: no commits between start_sha ($start_sha) and HEAD on main" >&2
    echo "       commit your work before marking the task done." >&2
    exit 1
fi

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp)
while IFS= read -r line; do
    case "$line" in
        state=*)      echo "state=done" ;;
        updated_at=*) echo "updated_at=$now" ;;
        summary=*)    echo "summary=$summary" ;;
        *)            echo "$line" ;;
    esac
done < "$state_file" > "$tmp"
mv "$tmp" "$state_file"

if [[ -z "${NIMBUS_TEST_MODE:-}" ]]; then
    osascript -e "display notification \"$slug: $summary\" with title \"Nimbus lightweight done\"" 2>/dev/null || true
    "$main_repo/scripts/wake-auditor.sh" "$slug" "done" 2>/dev/null || true
fi

echo "marked $slug done."
