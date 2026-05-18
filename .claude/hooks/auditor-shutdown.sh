#!/usr/bin/env bash
# SessionEnd hook: when the auditor's claude session terminates, kill
# all worker tmux sessions (so worker claudes stop making API calls
# unsupervised) and mark any active worker state as `orphaned`.
#
# Soft shutdown — preserves worktrees, branches, commits, mailboxes,
# and state files. The next `<project>-audit` boot will see orphaned
# workers in list-workers and the auditor (or you) can decide whether
# to resume each (`<project>-worker-resume <slug>`) or cancel them
# (`./scripts/cancel-worker.sh <slug>`).
#
# First arg is the project name (default "nimbus"); the hook reads
# <PROJECT_UPPER>_ROLE from the environment and parameterizes tmux
# session names (`<project>-workers`, `<project>-dashboard`) and the
# macOS notification title.
#
# Scoped to the auditor role; non-auditor sessions are no-ops. The
# settings.json matcher excludes `clear` and `resume` so /clear and
# --resume don't trigger shutdown.

set -u

project="${1:-nimbus}"
project_upper="$(printf '%s' "$project" | tr '[:lower:]' '[:upper:]')"
project_cap="$(printf '%s' "$project" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
role_var="${project_upper}_ROLE"

if [[ "${!role_var:-}" != "auditor" ]]; then
    exit 0
fi

# Best-effort: find the repo root so we can locate .auditor-state/.
# `cwd` is provided in the hook input JSON, but for SessionEnd we may
# not have a live working directory anymore; if we can't determine
# a valid project root, skip the state-mutation half and just kill tmux.
repo_root=""
if cwd_input=$(cat); then
    repo_root=$(printf '%s' "$cwd_input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("cwd", ""))
except Exception:
    pass
' 2>/dev/null || true)
fi

state_dir=""
if [[ -n "$repo_root" && -d "$repo_root/.auditor-state" ]]; then
    state_dir="$repo_root/.auditor-state"
fi

# Kill the worker tmux session — stops all worker claude processes.
# Also kill the dashboard if it's running so it stops re-rendering
# stale state.
if command -v tmux >/dev/null 2>&1; then
    tmux kill-session -t "${project}-workers"   2>/dev/null || true
    tmux kill-session -t "${project}-dashboard" 2>/dev/null || true
fi

# Mark active workers as orphaned. Preserves everything else.
if [[ -n "$state_dir" && -d "$state_dir" ]]; then
    orphaned_count=0
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    shopt -s nullglob
    for state_file in "$state_dir"/*.state; do
        s=$(grep '^state=' "$state_file" | head -1 | cut -d= -f2-)
        if [[ "$s" == "running" || "$s" == "blocked" ]]; then
            tmp=$(mktemp)
            while IFS= read -r line; do
                case "$line" in
                    state=*)      echo "state=orphaned" ;;
                    updated_at=*) echo "updated_at=$now" ;;
                    *)            echo "$line" ;;
                esac
            done < "$state_file" > "$tmp"
            mv "$tmp" "$state_file"
            orphaned_count=$((orphaned_count + 1))
        fi
    done
    shopt -u nullglob

    if [[ "$orphaned_count" -gt 0 ]]; then
        osascript -e "display notification \"$orphaned_count worker(s) orphaned by auditor shutdown\" with title \"$project_cap auditor\"" 2>/dev/null || true
    fi
fi

exit 0
