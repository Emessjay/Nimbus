#!/usr/bin/env bash
# PreToolUse hook for Bash: when NIMBUS_ROLE=lightweight, block any
# command that would orchestrate other agents or mutate git beyond what
# a lightweight needs (commit on its own fix/<slug>, read-only inspection).
#
# Allowed:
#   git commit / git add / git diff / git log / git status / git show
#   ./scripts/lightweight-done.sh
#   ./scripts/lightweight-blocked.sh
#   editing files, running formatters
#
# Blocked:
#   ./scripts/spawn-*.sh, ./scripts/merge-*.sh, ./scripts/cancel-worker.sh,
#   ./scripts/talk-to-*.sh, ./scripts/worker-*.sh, ./scripts/debugger-*.sh
#   git push / git rebase / git reset --hard / git branch -D / git worktree
#   git checkout <anything-not-fix/its-own-slug>
#
# Other roles unaffected.

set -u

if [[ "${NIMBUS_ROLE:-}" != "lightweight" ]]; then
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

my_slug="${NIMBUS_WORKER_SLUG:-}"

block_patterns=(
    'scripts/spawn-[a-z]+\.sh'
    'scripts/merge-[a-z]+\.sh'
    'scripts/cancel-worker\.sh'
    'scripts/talk-to-[a-z]+\.sh'
    'scripts/worker-(done|blocked|handoff|status|output)\.sh'
    'scripts/debugger-[a-z]+\.sh'
    'git[[:space:]]+push'
    'git[[:space:]]+rebase'
    'git[[:space:]]+reset[[:space:]]+--hard'
    'git[[:space:]]+branch[[:space:]]+-D'
    'git[[:space:]]+branch[[:space:]]+--delete'
    'git[[:space:]]+worktree'
    '--amend'
)

for pat in "${block_patterns[@]}"; do
    if [[ "$cmd" =~ $pat ]]; then
        cat >&2 <<EOF
BLOCKED: lightweights cannot run that command.
  command: $cmd
  matched: $pat

A lightweight commits on its fix/$my_slug branch and signals state with:
  ./scripts/lightweight-done.sh "<summary>"     when the trivial fix is committed
  ./scripts/lightweight-blocked.sh "<reason>"   when the task is bigger than it looked

The auditor handles merge / cancel / escalation. See LIGHTWEIGHT.md.
EOF
        exit 2
    fi
done

# Block git checkout of anything other than this lightweight's own branch.
# This stops the lightweight from accidentally switching the main
# checkout to a different branch.
if [[ "$cmd" =~ git[[:space:]]+checkout[[:space:]]+([^[:space:]]+) ]]; then
    target="${BASH_REMATCH[1]}"
    case "$target" in
        --|-b|-B|-f|-q|-)
            # Flag-only invocation; let it through and rely on follow-up parsing.
            ;;
        "fix/$my_slug")
            ;;
        *)
            cat >&2 <<EOF
BLOCKED: lightweight may not 'git checkout' to a non-fix/$my_slug ref.
  command: $cmd
  target:  $target

Stay on fix/$my_slug. The auditor will switch back to main during merge.
EOF
            exit 2
            ;;
    esac
fi

exit 0
