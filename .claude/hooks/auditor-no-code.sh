#!/usr/bin/env bash
# PreToolUse hook: block Edit/Write/NotebookEdit when the running
# Claude session has <PROJECT>_ROLE=auditor set. Configured in
# .claude/settings.json under hooks.PreToolUse.
#
# First arg is the project name (e.g. "nimbus", "aletheia"); the hook
# reads <PROJECT_UPPER>_ROLE from the environment. Default project is
# "nimbus" so invocations without an arg keep working.
#
# Allowed exception: any Markdown file (`*.md`). The auditor may edit
# documentation directly (CLAUDE.md, AUDITOR.md, WORKER.md, READMEs,
# design notes, etc.). Everything else under the source tree must be
# delegated to a worker via scripts/spawn-worker.sh.

set -u

project="${1:-nimbus}"
role_var="$(printf '%s' "$project" | tr '[:lower:]' '[:upper:]')_ROLE"

# Workers and ordinary sessions do not set this env var, so the hook
# is a no-op for them.
if [[ "${!role_var:-}" != "auditor" ]]; then
    exit 0
fi

# Read tool input (PreToolUse hook protocol delivers it as JSON on stdin).
input=$(cat)

# Extract tool_name and file_path. python3 is always available on macOS.
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

# Allow Markdown edits even in auditor mode.
case "$(basename "$file_path")" in
    *.md)
        exit 0
        ;;
esac

cat >&2 <<EOF
BLOCKED: the auditor cannot edit code directly.

  tool: ${tool_name:-?}
  file: ${file_path:-?}

Delegate to a worker instead:
  ./scripts/spawn-worker.sh <slug> "<task with acceptance criteria>"

Or send revisions to an existing worker:
  ./scripts/talk-to-worker.sh <slug> "<feedback>"

The auditor may freely edit any Markdown (*.md) file.

See AUDITOR.md for the full handbook.
EOF
exit 2
