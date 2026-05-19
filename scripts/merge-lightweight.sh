#!/usr/bin/env bash
# Accept a done lightweight. There is no branch to fast-forward and no
# checkout to restore — the lightweight committed directly to `main`,
# so this is purely a state transition: state=done → state=merged,
# tmux window killed, mailbox dropped.
#
# Usage:
#   ./scripts/merge-lightweight.sh <slug>
#
# Run from the main repo root by the auditor.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <slug>" >&2
    exit 1
fi

slug="$1"

repo_root="$(git rev-parse --show-toplevel)"
state_dir="$repo_root/.auditor-state"
state_file="$state_dir/$slug.state"

if [[ ! -f "$state_file" ]]; then
    echo "error: no state for $slug" >&2
    exit 1
fi

role=$(grep '^role=' "$state_file" | head -1 | cut -d= -f2-)
if [[ "$role" != "lightweight" ]]; then
    echo "error: $slug has role=$role, not lightweight; use merge-worker.sh" >&2
    exit 1
fi

state=$(grep '^state=' "$state_file" | head -1 | cut -d= -f2-)
if [[ "$state" != "done" ]]; then
    echo "error: lightweight state is '$state', not 'done'." >&2
    exit 1
fi

start_sha=$(grep '^start_sha=' "$state_file" | head -1 | cut -d= -f2- || true)
head_sha=$(git -C "$repo_root" rev-parse HEAD)

# Kill the lightweight's tmux window. It's done; leave-running would
# just leave a dead Claude session.
if command -v tmux >/dev/null 2>&1; then
    tmux kill-window -t "nimbus-workers:${slug}-light" 2>/dev/null || true
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

if [[ -n "$start_sha" ]]; then
    echo "accepted lightweight \`$slug\`; commits already on \`main\` from \`$start_sha\` to \`$head_sha\`."
else
    echo "accepted lightweight \`$slug\`; commits already on \`main\` (HEAD: \`$head_sha\`)."
fi
