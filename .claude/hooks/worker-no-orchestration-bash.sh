#!/usr/bin/env bash
# PreToolUse hook for Bash: when <PROJECT>_ROLE=worker, block the
# auditor-side orchestration scripts. Workers must not spawn or merge
# or cancel workers (including themselves) — that role belongs to the
# auditor exclusively. Workers communicate state with worker-done.sh
# and worker-blocked.sh; the auditor decides what happens next.
#
# First arg is the project name (default "nimbus"); the hook reads
# <PROJECT_UPPER>_ROLE from the environment. The auditor role and
# ordinary sessions are unaffected by this hook.

set -u

project="${1:-nimbus}"
role_var="$(printf '%s' "$project" | tr '[:lower:]' '[:upper:]')_ROLE"

if [[ "${!role_var:-}" != "worker" ]]; then
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

# Workers must not invoke any of these. Note: worker-handoff.sh IS
# allowed for paired workers — it's the worker-side counterpart of
# debugger-handoff.sh, not an orchestration command.
block_patterns=(
    'scripts/spawn-[a-z]+\.sh'
    'scripts/merge-[a-z]+\.sh'
    'scripts/cancel-worker\.sh'
    'scripts/talk-to-[a-z]+\.sh'
    'scripts/debugger-(handoff|approve|blocked)\.sh'
    'scripts/lightweight-(done|blocked)\.sh'
)

for pat in "${block_patterns[@]}"; do
    if [[ "$cmd" =~ $pat ]]; then
        cat >&2 <<EOF
BLOCKED: workers cannot run orchestration scripts.
  command: $cmd
  matched: $pat

Workers communicate state with:
  ./scripts/worker-done.sh "<summary>"      mark task complete (solo)
  ./scripts/worker-handoff.sh "<summary>"   hand off to debugger (paired)
  ./scripts/worker-blocked.sh "<reason>"    ask the auditor to decide

The auditor decides what to merge, cancel, or spawn next.
See WORKER.md.
EOF
        exit 2
    fi
done

exit 0
