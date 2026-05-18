#!/usr/bin/env bash
# PreToolUse hook for Read: when <PROJECT>_ROLE=critic, block reads
# of source files inside the home repo. The critic's whole point is
# to review the product from the outside; reading source defeats it.
#
# Allowed reads inside the cwd:
#   .auditor-state/<slug>.task             — the brief
#   .auditor-state/<slug>.state            — state file (diagnostics)
#   .auditor-state/<slug>.critique.md      — re-read own critique
#   .auditor-state/<slug>.screenshots/...  — re-read own screenshots
#   CRITIC.md                              — the handbook
#   CLAUDE.md                              — home repo notes
#
# Absolute paths OUTSIDE the cwd are unrestricted (so browser
# automation that writes screenshots to /tmp can read them back, and
# absolute references to $NIMBUS_HOME/CRITIC.md resolve).
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

cwd=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("cwd", ""))
except Exception:
    pass
' 2>/dev/null || true)

my_slug="${!slug_var:-}"

# If we can't determine cwd, fall back to refusing absolute paths only
# when they live inside what we can guess. Be permissive on the safe
# direction (allow), since the auditor will see anomalies in the
# critique anyway. The 99% case is that cwd is set.
if [[ -z "$cwd" ]]; then
    exit 0
fi

# Resolve the read target. Bash basename handling is fine; we just
# need the resolved relationship to cwd.
target="$file_path"
# Treat empty file_path defensively.
if [[ -z "$target" ]]; then
    exit 0
fi

# If target is relative, anchor it under cwd for the inside-cwd check.
case "$target" in
    /*) abs="$target" ;;
    *)  abs="$cwd/$target" ;;
esac

# Outside the home repo? Always allow.
case "$abs" in
    "$cwd"/*) inside=1 ;;
    "$cwd")   inside=1 ;;
    *)        inside=0 ;;
esac

if [[ "$inside" -eq 0 ]]; then
    exit 0
fi

# Inside cwd: allowlist the critic's own files and the two handbooks.
rel="${abs#$cwd/}"
case "$rel" in
    "CRITIC.md"|"CLAUDE.md")
        exit 0 ;;
    ".auditor-state/${my_slug}.task")
        exit 0 ;;
    ".auditor-state/${my_slug}.state")
        exit 0 ;;
    ".auditor-state/${my_slug}.critique.md")
        exit 0 ;;
    ".auditor-state/${my_slug}.screenshots/"*)
        exit 0 ;;
esac

cat >&2 <<EOF
BLOCKED: the critic cannot read source files in the home repo.

  file:  ${file_path:-?}
  slug:  ${my_slug:-?}

The point of the critic tier is a code-blind review — if you read
the implementation, you start grading the code instead of the product.

Allowed reads inside the home repo:
  .auditor-state/${my_slug:-<slug>}.task
  .auditor-state/${my_slug:-<slug>}.state
  .auditor-state/${my_slug:-<slug>}.critique.md
  .auditor-state/${my_slug:-<slug>}.screenshots/*
  CRITIC.md
  CLAUDE.md

Absolute paths outside the home repo are unrestricted (e.g. screenshots
your browser tool wrote to /tmp, or \$NIMBUS_HOME/CRITIC.md by absolute
path). See CRITIC.md.
EOF
exit 2
