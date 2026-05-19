#!/usr/bin/env bash
# Accept a critic's findings: kill its tmux window, mark state=merged.
# Despite the name "merge", there is no branch to merge — critics never
# touched code. This is the auditor's "I've digested the critique and
# we're done with the critic" verb. After this, the auditor typically
# summarizes the critique for the user and ends its turn.
#
# Usage:
#   ./scripts/merge-critic.sh <slug>           # only if state == done
#   ./scripts/merge-critic.sh <slug> --force   # ignore state
#
# The critique file and screenshots directory are LEFT IN PLACE as an
# archive — the auditor / user may want to reference them after the
# critic is gone. Use cancel-worker.sh <slug> to remove the critic's
# state files entirely.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <slug> [--force]" >&2
    exit 1
fi

slug="$1"
force="${2:-}"

repo_root="$(git rev-parse --show-toplevel)"
state_dir="$repo_root/.auditor-state"
state_file="$state_dir/$slug.state"

if [[ ! -f "$state_file" ]]; then
    echo "error: no state for $slug" >&2
    exit 1
fi

role=$(grep '^role=' "$state_file" | head -1 | cut -d= -f2- || true)
if [[ "$role" != "critic" ]]; then
    echo "error: $slug has role=${role:-<missing>}, not critic; use merge-worker.sh or merge-lightweight.sh" >&2
    exit 1
fi

state=$(grep '^state=' "$state_file" | head -1 | cut -d= -f2-)
if [[ "$state" != "done" && "$force" != "--force" ]]; then
    echo "error: critic state is '$state', not 'done'." >&2
    echo "       pass --force to merge anyway." >&2
    exit 1
fi

# Kill the critic's tmux window. There's no branch or worktree to
# touch — critics observe only.
if command -v tmux >/dev/null 2>&1; then
    tmux kill-window -t "nimbus-workers:${slug}-crit" 2>/dev/null || true
fi

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp)
while IFS= read -r line; do
    case "$line" in
        state=*)      echo "state=merged" ;;
        updated_at=*) echo "updated_at=$now" ;;
        *)            echo "$line" ;;
    esac
done < "$state_file" > "$tmp"
mv "$tmp" "$state_file"

rm -f "$state_dir/$slug.mailbox"

critique_file="$state_dir/$slug.critique.md"
screenshots_dir="$state_dir/$slug.screenshots"

echo "accepted critic $slug:"
echo "  - killed tmux window nimbus-workers:${slug}-crit"
echo "  - state set to merged"
if [[ -f "$critique_file" ]]; then
    echo "  - archived critique: $critique_file"
fi
if [[ -d "$screenshots_dir" ]]; then
    echo "  - archived screenshots: $screenshots_dir"
fi
echo
echo "To remove the archive: ./scripts/cancel-worker.sh $slug"
