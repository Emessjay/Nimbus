#!/usr/bin/env bash
# PreToolUse hook for Bash: when <PROJECT>_ROLE=critic, block any
# orchestration script. Critics observe; they do not spawn, merge,
# cancel, or message other agents — and crucially they must not run
# spawn-critic / merge-critic / talk-to-critic on themselves.
#
# First arg is the project name (default "nimbus"); the hook reads
# <PROJECT_UPPER>_ROLE from the environment.

set -u

project="${1:-nimbus}"
role_var="$(printf '%s' "$project" | tr '[:lower:]' '[:upper:]')_ROLE"

if [[ "${!role_var:-}" != "critic" ]]; then
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

# Same shape as worker-no-orchestration-bash.sh, plus the critic-side
# scripts that the critic must not call on itself. critic-done.sh and
# critic-blocked.sh are the only allowed critic-side verbs.
block_patterns=(
    'scripts/spawn-[a-z]+\.sh'
    'scripts/merge-[a-z]+\.sh'
    'scripts/cancel-worker\.sh'
    'scripts/talk-to-[a-z]+\.sh'
    'scripts/debugger-(handoff|approve|blocked)\.sh'
    'scripts/lightweight-(done|blocked)\.sh'
    'scripts/worker-(done|blocked|handoff|status|output)\.sh'
)

for pat in "${block_patterns[@]}"; do
    if [[ "$cmd" =~ $pat ]]; then
        cat >&2 <<EOF
BLOCKED: critics cannot run orchestration scripts.
  command: $cmd
  matched: $pat

A critic's only verbs are:
  ./scripts/critic-done.sh "<summary>"      after writing the critique
  ./scripts/critic-blocked.sh "<reason>"    if the feature is unreachable

The auditor decides what to do with your critique. See CRITIC.md.
EOF
        exit 2
    fi
done

exit 0
