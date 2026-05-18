#!/usr/bin/env bash
# PreToolUse hook for Agent: when NIMBUS_ROLE=lightweight, allow only
# read-only sub-agent types. A lightweight is a single-shot fixer; it
# has no business spawning editing sub-agents.

set -u

if [[ "${NIMBUS_ROLE:-}" != "lightweight" ]]; then
    exit 0
fi

input=$(cat)

subagent_type=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("subagent_type", ""))
except Exception:
    pass
' 2>/dev/null || true)

case "$subagent_type" in
    Explore|Plan|claude-code-guide|statusline-setup)
        exit 0
        ;;
esac

cat >&2 <<EOF
BLOCKED: lightweight cannot spawn an editing sub-agent.
  subagent_type: ${subagent_type:-"<unspecified; defaults to general-purpose>"}

A lightweight does the trivial fix directly. If the task warrants
spawning sub-agents, it warrants a real worker — call:
  ./scripts/lightweight-blocked.sh "scope grew, needs a worker"

See LIGHTWEIGHT.md.
EOF
exit 2
