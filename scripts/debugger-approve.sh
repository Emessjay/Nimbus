#!/usr/bin/env bash
# Called by a debugger to declare the pair done. From the auditor's
# perspective this is identical to a solo worker reporting done — same
# state transition, same notification, same merge path. Auditor is
# still the final reviewer; debugger does not bypass merge.
#
# Usage:
#   ./scripts/debugger-approve.sh "<one-line summary>"
#
# Must be run inside the pair's worktree. Refuses if the worker has no
# commits ahead of main (catches "approving" before a worker handoff
# ever happened).

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 \"<summary>\"" >&2
    exit 1
fi

summary="$*"

worktree="$(git rev-parse --show-toplevel)"
main_repo=$(git worktree list --porcelain | awk '/^worktree / { print $2; exit }')

slug="${NIMBUS_WORKER_SLUG:-}"
if [[ -z "$slug" ]]; then
    main_basename="${main_repo##*/}"
    worktree_name="${worktree##*/}"
    if [[ "$worktree_name" != "${main_basename}-"* ]]; then
        echo "error: NIMBUS_WORKER_SLUG unset and cwd is not a '${main_basename}-<slug>' worktree" >&2
        exit 1
    fi
    slug="${worktree_name#${main_basename}-}"
fi
state_dir="$main_repo/.auditor-state"
state_file="$state_dir/$slug.state"
review_log="$state_dir/$slug.review.log"

if [[ ! -f "$state_file" ]]; then
    echo "error: no state for $slug" >&2
    exit 1
fi
pair_mode=$(grep '^pair_mode=' "$state_file" | head -1 | cut -d= -f2-)
if [[ "$pair_mode" != "paired" ]]; then
    echo "error: $slug is not a pair" >&2
    exit 1
fi

ahead=$(git rev-list --count main..HEAD 2>/dev/null || echo "0")
if [[ "$ahead" -eq 0 ]]; then
    echo "error: no commits ahead of main; nothing to approve" >&2
    exit 1
fi

# Integrate main before flipping state, so the auditor's merge-worker
# is always a fast-forward. If the merge conflicts, leave state
# untouched and bail — the pair resolves and reruns this script.
if ! git merge-base --is-ancestor main HEAD; then
    echo "main has moved since you branched; integrating..."
    if git merge main --no-edit; then
        echo "merged main into $(git branch --show-current) cleanly."
    else
        git merge --abort
        cat >&2 <<EOF
error: main moved while you worked and merging produces conflicts.
       Resolve manually:
           git merge main
           # edit conflicted files, then:
           git add <files>
           git commit
       Then call this script again.
EOF
        exit 1
    fi
fi

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp)
while IFS= read -r line; do
    case "$line" in
        state=*)      echo "state=done" ;;
        pair_state=*) echo "pair_state=approved" ;;
        updated_at=*) echo "updated_at=$now" ;;
        summary=*)    echo "summary=$summary" ;;
        *)            echo "$line" ;;
    esac
done < "$state_file" > "$tmp"
mv "$tmp" "$state_file"

{
    echo "[$now] DEBUGGER APPROVED:"
    echo "$summary"
    echo ""
} >> "$review_log"

if [[ -z "${NIMBUS_TEST_MODE:-}" ]]; then
    osascript -e "display notification \"$slug: $summary\" with title \"Nimbus pair approved\"" 2>/dev/null || true
    "$main_repo/scripts/wake-auditor.sh" "$slug" "done" 2>/dev/null || true
fi

echo "approved $slug. The auditor will see this as 'worker $slug done' on its next prompt and can merge with:"
echo "    ./scripts/merge-worker.sh $slug"
