#!/usr/bin/env bash
# PreToolUse hook for Agent: when <PROJECT>_ROLE=auditor, allow only
# read-only / non-editing sub-agent types. The auditor must not spawn
# a coding sub-agent — that path bypasses worker-worktree isolation,
# auditor-review, and the 5-worker cap.
#
# First arg is the project name (default "nimbus"); the hook reads
# <PROJECT_UPPER>_ROLE from the environment.
#
# Read-only sub-agent types allowed:
#   Explore           code search / file lookup
#   Plan              architecture / implementation planning
#   claude-code-guide Claude Code documentation lookups
#   statusline-setup  tiny config edit (irrelevant to auditing but harmless)
#
# Anything else (including the default catch-all "claude" and
# "general-purpose") is refused.

set -u

project="${1:-nimbus}"
role_var="$(printf '%s' "$project" | tr '[:lower:]' '[:upper:]')_ROLE"

if [[ "${!role_var:-}" != "auditor" ]]; then
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
BLOCKED: auditor cannot spawn an editing sub-agent.
  subagent_type: ${subagent_type:-"<unspecified; defaults to general-purpose>"}

The auditor's sub-agents are restricted to read-only kinds:
  subagent_type: Explore  for code search / file lookups
  subagent_type: Plan     for architecture / planning

To actually write code, spawn a worker:
  ./scripts/spawn-worker.sh <slug> "<task>"

See AUDITOR.md.
EOF
exit 2
