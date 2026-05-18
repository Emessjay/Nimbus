#!/usr/bin/env bash
# List all worker state. Used by the auditor for situational awareness.
#
# Usage:
#   ./scripts/list-workers.sh         # active workers only
#   ./scripts/list-workers.sh --all   # including merged
#
# Output is one line per worker, plus a "BLOCKED" callout at the end
# for any worker that needs the auditor's attention.

set -euo pipefail

show_all=0
if [[ "${1:-}" == "--all" ]]; then
    show_all=1
fi

repo_root="$(git rev-parse --show-toplevel)"
state_dir="$repo_root/.auditor-state"

shopt -s nullglob
state_files=("$state_dir"/*.state)
shopt -u nullglob

if [[ ${#state_files[@]} -eq 0 ]]; then
    echo "no workers"
    exit 0
fi

# Headline the tmux attach command if any workers are alive in tmux.
if command -v tmux >/dev/null 2>&1 \
   && tmux has-session -t nimbus-workers 2>/dev/null; then
    live_count=$(tmux list-windows -t nimbus-workers 2>/dev/null | wc -l | tr -d ' ')
    echo "tmux: nimbus-workers session has $live_count window(s) — attach with: tmux attach -t nimbus-workers"
    echo
fi

printf "%-28s %-12s %-10s %-32s %-7s %-7s %-8s\n" "SLUG" "KIND" "STATE" "BRANCH" "AHEAD" "ROUNDS" "AGE"

for state_file in "${state_files[@]}"; do
    slug=$(grep '^slug=' "$state_file" | head -1 | cut -d= -f2-)
    state=$(grep '^state=' "$state_file" | head -1 | cut -d= -f2-)
    branch=$(grep '^branch=' "$state_file" | head -1 | cut -d= -f2-)
    spawned=$(grep '^spawned_at=' "$state_file" | head -1 | cut -d= -f2-)
    summary=$(grep '^summary=' "$state_file" | head -1 | cut -d= -f2-)
    blocked_reason=$(grep '^blocked_reason=' "$state_file" | head -1 | cut -d= -f2-)
    # New per-tier fields may be absent on older or simpler state files;
    # tolerate via `|| true` so set -e / pipefail doesn't kill the loop.
    role=$(grep '^role=' "$state_file" | head -1 | cut -d= -f2- || true)
    pair_mode=$(grep '^pair_mode=' "$state_file" | head -1 | cut -d= -f2- || true)
    pair_state=$(grep '^pair_state=' "$state_file" | head -1 | cut -d= -f2- || true)
    review_rounds=$(grep '^review_rounds=' "$state_file" | head -1 | cut -d= -f2- || true)
    review_cap=$(grep '^review_cap=' "$state_file" | head -1 | cut -d= -f2- || true)

    if [[ "$show_all" -eq 0 && ( "$state" == "merged" || "$state" == "cancelled" ) ]]; then
        continue
    fi

    # Pretty kind: worker | pair | lightweight.
    kind="${role:-worker}"
    [[ "$pair_mode" == "paired" ]] && kind="pair"

    # Rounds column: "-" for solo workers/lightweights, "N/M" for pairs.
    rounds="-"
    if [[ "$pair_mode" == "paired" ]]; then
        rounds="${review_rounds:-0}/${review_cap:-?}"
    fi

    # Count commits ahead of main.
    ahead="-"
    if git -C "$repo_root" rev-parse --verify "$branch" >/dev/null 2>&1; then
        ahead=$(git -C "$repo_root" rev-list --count "main..$branch" 2>/dev/null || echo "?")
    fi

    # Compute age from spawned_at. -u is critical: spawned_at is in UTC,
    # and without it macOS `date -j -f` would parse it as local time.
    age="?"
    if spawned_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$spawned" "+%s" 2>/dev/null); then
        now_epoch=$(date -u +%s)
        diff=$((now_epoch - spawned_epoch))
        if   [[ "$diff" -lt 60 ]];    then age="${diff}s"
        elif [[ "$diff" -lt 3600 ]];  then age="$((diff / 60))m"
        elif [[ "$diff" -lt 86400 ]]; then age="$((diff / 3600))h"
        else                               age="$((diff / 86400))d"
        fi
    fi

    printf "%-28s %-12s %-10s %-32s %-7s %-7s %-8s\n" "$slug" "$kind" "$state" "$branch" "$ahead" "$rounds" "$age"

    # Inline annotation: blocked_reason, summary, orphaned hint, or
    # pending mailbox.
    if [[ "$state" == "blocked" && -n "$blocked_reason" ]]; then
        echo "    blocked: $blocked_reason"
    fi
    if [[ "$state" == "done" && -n "$summary" ]]; then
        echo "    summary: $summary"
    fi
    if [[ "$pair_mode" == "paired" && -n "$pair_state" && "$state" == "running" ]]; then
        echo "    pair: $pair_state (rounds $rounds)"
    fi
    if [[ "$state" == "orphaned" ]]; then
        echo "    orphaned: auditor exited while this $kind was active"
        if [[ "$role" == "lightweight" ]]; then
            echo "      lightweights are not resume-friendly; cancel and respawn:"
            echo "      cancel: ./scripts/cancel-worker.sh $slug"
        else
            echo "      resume: nimbus-worker-resume $slug"
            echo "      cancel: ./scripts/cancel-worker.sh $slug"
        fi
    fi
    mailbox="$state_dir/$slug.mailbox"
    if [[ -s "$mailbox" ]]; then
        # Messages are separated by lines containing only `---`; count
        # separators and add one.
        msg_count=$(grep -c '^---$' "$mailbox" 2>/dev/null || echo 0)
        msg_count=$((msg_count + 1))
        echo "    mailbox: $msg_count message(s) queued (worker is offline)"
    fi
done
