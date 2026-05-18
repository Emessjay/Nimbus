#!/usr/bin/env bash
# PreToolUse hook for Edit/Write/NotebookEdit: when <PROJECT>_ROLE=critic,
# block any edit/write outside the critic's own outputs. The critic
# does not edit code, docs, or anything else — its only writable
# destinations are .auditor-state/<slug>.critique.md and anything
# under .auditor-state/<slug>.screenshots/.
#
# First arg is the project name (default "nimbus"); the hook reads
# <PROJECT_UPPER>_ROLE and <PROJECT_UPPER>_WORKER_SLUG from the
# environment.

set -u

project="${1:-nimbus}"
project_upper="$(printf '%s' "$project" | tr '[:lower:]' '[:upper:]')"
role_var="${project_upper}_ROLE"
slug_var="${project_upper}_WORKER_SLUG"

if [[ "${!role_var:-}" != "critic" ]]; then
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

my_slug="${!slug_var:-}"

# Allowed write destinations:
#   - .auditor-state/<slug>.critique.md
#   - anything under .auditor-state/<slug>.screenshots/
# Both relative and absolute paths are matched. The substring match on
# the slug-scoped paths is sufficient because tool_input.file_path is
# the literal path the agent passed (we don't need to resolve symlinks).
if [[ -n "$my_slug" ]]; then
    case "$file_path" in
        *"/.auditor-state/${my_slug}.critique.md")
            exit 0 ;;
        *"/.auditor-state/${my_slug}.screenshots/"*)
            exit 0 ;;
        ".auditor-state/${my_slug}.critique.md")
            exit 0 ;;
        ".auditor-state/${my_slug}.screenshots/"*)
            exit 0 ;;
    esac
fi

cat >&2 <<EOF
BLOCKED: the critic cannot edit files outside its own outputs.

  tool:  ${tool_name:-?}
  file:  ${file_path:-?}
  slug:  ${my_slug:-?}

A critic writes ONLY to:
  .auditor-state/${my_slug:-<slug>}.critique.md       its findings report
  .auditor-state/${my_slug:-<slug>}.screenshots/...   captured screens

Source code, docs, configs — none of it. If your critique requires
proving something about the code, name it in the critique and let the
auditor decide whether to spawn a worker. See CRITIC.md.
EOF
exit 2
