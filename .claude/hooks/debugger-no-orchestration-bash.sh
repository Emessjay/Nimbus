#!/usr/bin/env bash
# PreToolUse hook for Bash: when <PROJECT>_ROLE=debugger, block any
# command that would orchestrate other agents or mutate the repo.
# Allowed: read-only git, npm test, cargo check/test, the three
# debugger verbs (debugger-handoff/approve/blocked).
#
# First arg is the project name (default "nimbus"); the hook reads
# <PROJECT_UPPER>_ROLE from the environment. Other roles unaffected.

set -u

project="${1:-nimbus}"
role_var="$(printf '%s' "$project" | tr '[:lower:]' '[:upper:]')_ROLE"

if [[ "${!role_var:-}" != "debugger" ]]; then
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

block_patterns=(
    'scripts/spawn-[a-z]+\.sh'
    'scripts/merge-[a-z]+\.sh'
    'scripts/cancel-worker\.sh'
    'scripts/talk-to-[a-z]+\.sh'
    'scripts/worker-(done|blocked|handoff)\.sh'
    'scripts/lightweight-(done|blocked)\.sh'
    'git[[:space:]]+commit'
    'git[[:space:]]+push'
    'git[[:space:]]+rebase'
    'git[[:space:]]+reset[[:space:]]+--hard'
    'git[[:space:]]+restore'
    'git[[:space:]]+checkout[[:space:]]+--'
    'git[[:space:]]+branch[[:space:]]+-D'
    'git[[:space:]]+branch[[:space:]]+--delete'
    'git[[:space:]]+worktree'
    '--amend'
)

for pat in "${block_patterns[@]}"; do
    if [[ "$cmd" =~ $pat ]]; then
        cat >&2 <<EOF
BLOCKED: debuggers cannot run that command.
  command: $cmd
  matched: $pat

A debugger reviews; it does not edit, commit, or orchestrate. Verbs:
  ./scripts/debugger-handoff.sh "<feedback>"   request revisions
  ./scripts/debugger-approve.sh "<summary>"    declare the pair done
  ./scripts/debugger-blocked.sh "<reason>"     escalate to the auditor

You may freely run: tests, builds, type checks, read-only git.
See DEBUGGER.md.
EOF
        exit 2
    fi
done

exit 0
