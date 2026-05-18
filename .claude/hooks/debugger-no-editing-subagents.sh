#!/usr/bin/env bash
# PreToolUse hook for Agent: when NIMBUS_ROLE=debugger, allow only
# read-only / non-editing sub-agent types. Mirrors the auditor's
# subagent restrictions — a coding sub-agent would let the debugger
# write code through the back door.

set -u

if [[ "${NIMBUS_ROLE:-}" != "debugger" ]]; then
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
BLOCKED: debugger cannot spawn an editing sub-agent.
  subagent_type: ${subagent_type:-"<unspecified; defaults to general-purpose>"}

Allowed (read-only):
  Explore, Plan, claude-code-guide, statusline-setup

A debugger reviews code; to request changes, message your paired worker:
  ./scripts/debugger-handoff.sh "<numbered revisions>"

See DEBUGGER.md.
EOF
exit 2
