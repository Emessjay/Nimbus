#!/usr/bin/env bash
# PreToolUse hook for Bash: block git commands that would mutate the
# repository directly when <PROJECT>_ROLE=auditor. The auditor's only
# sanctioned mutating path is through the worker scripts; running
# `git commit` etc. directly bypasses worker review.
#
# First arg is the project name (default "nimbus"); the hook reads
# <PROJECT_UPPER>_ROLE from the environment. Workers and ordinary
# sessions (no role set) are unaffected.

set -u

project="${1:-nimbus}"
role_var="$(printf '%s' "$project" | tr '[:lower:]' '[:upper:]')_ROLE"

if [[ "${!role_var:-}" != "auditor" ]]; then
    exit 0
fi

input=$(cat)

cmd=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("command", ""))
except Exception:
    pass
' 2>/dev/null || true)

# Commands invoked through our sanctioned scripts are always allowed —
# the scripts internally call git commit / git worktree remove / etc.
# but they implement the auditor's mandate, not a bypass of it.
if [[ "$cmd" =~ scripts/(spawn-worker|spawn-pair|spawn-lightweight|merge-worker|merge-lightweight|cancel-worker|talk-to-worker|talk-to-debugger)\.sh ]]; then
    exit 0
fi

# Patterns the auditor must not run directly. Word boundaries via
# [[:space:]] so e.g. "git committee-helper" wouldn't false-match
# "git commit".
block_patterns=(
    'git[[:space:]]+commit'
    'git[[:space:]]+push'
    'git[[:space:]]+reset[[:space:]]+--hard'
    'git[[:space:]]+restore'
    'git[[:space:]]+checkout[[:space:]]+--'
    'git[[:space:]]+rebase'
    'git[[:space:]]+revert'
    'git[[:space:]]+stash[[:space:]]+drop'
    'git[[:space:]]+branch[[:space:]]+-D'
    'git[[:space:]]+branch[[:space:]]+--delete'
    'git[[:space:]]+worktree[[:space:]]+remove'
    'git[[:space:]]+worktree[[:space:]]+add'
    '--amend'
)

for pat in "${block_patterns[@]}"; do
    if [[ "$cmd" =~ $pat ]]; then
        cat >&2 <<EOF
BLOCKED: auditor cannot run mutating git/repo commands directly.
  command:        $cmd
  matched:        $pat

The auditor's sanctioned mutating commands are:
  ./scripts/spawn-worker.sh        start a worker
  ./scripts/spawn-pair.sh          start a worker + debugger pair
  ./scripts/spawn-lightweight.sh   start a lightweight (trivial fix, no worktree)
  ./scripts/talk-to-worker.sh      send revisions to a worker
  ./scripts/talk-to-debugger.sh    send a note to a paired debugger
  ./scripts/merge-worker.sh        land a worker's commits onto main
  ./scripts/merge-lightweight.sh   fast-forward a lightweight onto main
  ./scripts/cancel-worker.sh       abort any kind of agent

If you need to change code, spawn an agent. If you need to land work
onto main, use the appropriate merge script. See AUDITOR.md.
EOF
        exit 2
    fi
done

exit 0
