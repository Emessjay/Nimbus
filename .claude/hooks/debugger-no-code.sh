#!/usr/bin/env bash
# PreToolUse hook: block Edit/Write/NotebookEdit when NIMBUS_ROLE=debugger.
#
# The debugger is the adversarial reviewer of one paired worker. It
# reads code, runs tests, and messages — it never edits, not even
# Markdown. Documentation updates are auditor territory.

set -u

if [[ "${NIMBUS_ROLE:-}" != "debugger" ]]; then
    exit 0
fi

input=$(cat)

file_path=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("file_path", ""))
except Exception:
    pass
' 2>/dev/null || true)

tool_name=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_name", ""))
except Exception:
    pass
' 2>/dev/null || true)

cat >&2 <<EOF
BLOCKED: the debugger cannot edit files.

  tool: ${tool_name:-?}
  file: ${file_path:-?}

A debugger reviews. To request changes, message your paired worker with:
  ./scripts/debugger-handoff.sh "<numbered revisions>"

If the spec is wrong, escalate:
  ./scripts/debugger-blocked.sh "<reason — spec gap, fundamental disagreement>"

See DEBUGGER.md.
EOF
exit 2
