#!/usr/bin/env bash
# Boot a worker / debugger / lightweight / critic Claude session inside
# a tmux window.
#
# Usage:
#   nimbus-worker.sh [--role worker|debugger|lightweight|critic] <slug>
#
# Called by spawn-worker.sh, spawn-pair.sh, spawn-lightweight.sh, or
# spawn-critic.sh inside the tmux window it creates. Not typically
# invoked directly. Reads the task and pre-assigned session ID from
# .auditor-state/<slug>.state in the main repo (resolved via
# `git worktree list`) and execs claude.
#
# Role drives:
#   - which handbook the boot prompt points at (WORKER.md / DEBUGGER.md /
#     LIGHTWEIGHT.md / CRITIC.md, all resolved against $NIMBUS_HOME so
#     the prompt works no matter which home repo Claude lands in)
#   - which verbs the boot prompt advertises (worker-done /
#     debugger-approve / critic-done / etc.)
#   - the NIMBUS_ROLE env var consumed by the PreToolUse hooks
#   - whether to use session_id or debugger_session_id from .state
#
# This is a standalone script (not a shell function) because tmux's
# new-window command runs a non-interactive shell which would not
# source ~/.zshrc.

set -euo pipefail

role="worker"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)
            role="${2:-}"
            shift 2
            ;;
        --role=*)
            role="${1#--role=}"
            shift
            ;;
        -*)
            echo "error: unknown flag $1" >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

case "$role" in
    worker|debugger|lightweight|critic) ;;
    *)
        echo "error: invalid role '$role' (must be worker|debugger|lightweight|critic)" >&2
        exit 1
        ;;
esac

slug="${1:-}"
if [[ -z "$slug" ]]; then
    echo "usage: $0 [--role worker|debugger|lightweight|critic] <slug>" >&2
    exit 1
fi

main_repo=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / { print $2; exit }')
if [[ -z "$main_repo" ]]; then
    echo "error: not inside a git repo" >&2
    exit 1
fi

# NIMBUS_HOME tells us where the handbook files live. spawn-* scripts
# inherit it from the auditor's tmux session env (set by nimbus-audit),
# and pass it through their tmux new-window -e flag. If it's missing,
# fall back to "two directories up from this script" — which is correct
# when Nimbus is its own home repo (e.g. running the test suite here).
nimbus_home="${NIMBUS_HOME:-}"
if [[ -z "$nimbus_home" ]]; then
    nimbus_home="$(cd "$(dirname "$0")/.." && pwd)"
fi

state_file="$main_repo/.auditor-state/$slug.state"
task_file="$main_repo/.auditor-state/$slug.task"
spec_file="$main_repo/.auditor-state/$slug.spec.md"

if [[ ! -f "$state_file" ]]; then
    echo "error: no state for $slug at $state_file" >&2
    exit 1
fi

task=""
[[ -f "$task_file" ]] && task=$(cat "$task_file")

effort=$(awk '/^effort=/ { print substr($0, index($0,"=")+1); exit }' "$state_file")
effort="${effort:-medium}"
# Optional model override; if unset, claude picks the default (Opus).
# Lightweights set model=sonnet to run cheaper.
model=$(awk '/^model=/ { print substr($0, index($0,"=")+1); exit }' "$state_file")

# Pick the session id field. Workers, lightweights, and critics use
# the canonical session_id; the debugger half of a pair uses
# debugger_session_id so the two halves of a paired feature have
# separate Claude sessions.
if [[ "$role" == "debugger" ]]; then
    session_id=$(awk '/^debugger_session_id=/ { print substr($0, index($0,"=")+1); exit }' "$state_file")
else
    session_id=$(awk '/^session_id=/ { print substr($0, index($0,"=")+1); exit }' "$state_file")
fi

# Construct the role-specific prompt. Every reference to a handbook
# uses the absolute $nimbus_home/<HANDBOOK>.md so the prompt resolves
# correctly regardless of which home repo the agent lands in.
claude_md_path="$nimbus_home/CLAUDE.md"
case "$role" in
    worker)
        spec_note=""
        if [[ -f "$spec_file" ]]; then
            spec_note="

The auditor has written a spec for this task at
    $spec_file
Read it before you start coding. It defines the acceptance criteria the
debugger (if any) and the auditor will review against. If the spec and
the task brief disagree, the spec wins."
        fi
        prompt="**read $claude_md_path and $nimbus_home/WORKER.md before you start**

Your slug: $slug
Your task:

$task
$spec_note

When done, commit your work and run:
    ./scripts/worker-done.sh \"<one-line summary>\"
If you are blocked on a top-level decision, run:
    ./scripts/worker-blocked.sh \"<reason>\"

If you are paired with a debugger (check pair_mode in
$state_file), commit a milestone and hand off for review with:
    ./scripts/worker-handoff.sh \"<one-line summary of what you just committed>\"

The auditor (and your debugger, if paired) will deliver revisions by
injecting them directly into your terminal via tmux. You do not need to
poll any file for them — they will simply appear as a new user prompt.
The mailbox at
    $main_repo/.auditor-state/$slug.mailbox
is a fallback for the rare case that a message was sent while your
session was offline; check it once on startup."
        ;;
    debugger)
        if [[ ! -f "$spec_file" ]]; then
            echo "error: debugger requires .auditor-state/$slug.spec.md to exist" >&2
            exit 1
        fi
        prompt="**read $claude_md_path and $nimbus_home/DEBUGGER.md before you act — you are the adversarial reviewer of one worker; you never edit code**

Your slug: $slug
Your paired worker is in tmux window: $slug (this window: $slug-dbg)
Shared worktree:
    $(awk '/^worktree_path=/ { print substr($0, index($0,"=")+1); exit }' "$state_file")

The auditor's spec at
    $spec_file
is your sole objective standard. Approve the moment the spec is
satisfied — do not nitpick beyond it. If you want to request something
the spec does not require, that is a sign the spec is missing a
criterion; surface it to the auditor via debugger-blocked.sh rather
than rejecting the worker over it.

The original task brief is also at
    $task_file
for context, but the spec governs approval.

Your verbs:
    ./scripts/debugger-handoff.sh \"<feedback>\"       — bounce back with numbered revisions
    ./scripts/debugger-approve.sh \"<summary>\"        — declare the pair done; the auditor reviews next
    ./scripts/debugger-blocked.sh \"<reason>\"         — escalate to the auditor (spec gap, fundamental disagreement, etc.)

You run tests, you read commits, you do not edit. A PreToolUse hook
will block any Edit/Write attempt."
        ;;
    lightweight)
        prompt="**read $claude_md_path and $nimbus_home/LIGHTWEIGHT.md before you act — you are a single-shot fixer for trivial changes**

Your slug: $slug
Your task:

$task

You are NOT in a worktree. You operate in the main checkout, directly
on \`main\` — there is no separate branch protecting main from your
commits. Touch only the files the brief names. If the task is bigger
than a few lines or needs tests, stop and run:
    ./scripts/lightweight-blocked.sh \"scope grew, needs a worker\"

When done, commit your work directly to \`main\` and run:
    ./scripts/lightweight-done.sh \"<one-line summary>\"
The auditor will accept your commits with merge-lightweight.sh (which
is now a state transition, since your commits are already on main)."
        ;;
    critic)
        prompt="**read $claude_md_path and $nimbus_home/CRITIC.md before you act — you review the UI as a user, never reading source code**

Your slug: $slug
Your task (the user paths to navigate and what to look for):

$task

You operate in the main checkout, not a worktree. You do NOT edit code:
PreToolUse hooks will block Edit / Write / NotebookEdit for any path
outside your own outputs. You also do NOT read source files: a hook
blocks Read on the home repo except for .auditor-state/$slug.task,
.auditor-state/$slug.state, .auditor-state/$slug.critique.md, anything
under .auditor-state/$slug.screenshots/, and the handbooks ($nimbus_home/CRITIC.md
and the home repo's CLAUDE.md).

Your output is a single markdown file at:
    $main_repo/.auditor-state/$slug.critique.md
Screenshots go under:
    $main_repo/.auditor-state/$slug.screenshots/

Use whatever browser-driving tool your home repo provides (e.g. a
Playwright/Puppeteer MCP, an Explore subagent that drives a headless
browser, or the system 'screencapture' if testing a desktop app).

When the critique is committed to disk, run:
    ./scripts/critic-done.sh \"<one-line summary of findings>\"
If you cannot reach the feature (app won't boot, login broken, etc.),
run:
    ./scripts/critic-blocked.sh \"<reason>\"

The auditor will deliver revision feedback via tmux; treat any incoming
prompt as the next user message."
        ;;
esac

export NIMBUS_ROLE="$role"
export NIMBUS_WORKER_SLUG="$slug"
export NIMBUS_HOME="$nimbus_home"

name_prefix="$role"
[[ "$role" == "worker" ]] && name_prefix="worker"

claude_args=(--effort "$effort" --name "$name_prefix:$slug")
[[ -n "$model" ]] && claude_args+=(--model "$model")
[[ -n "$session_id" ]] && claude_args=(--session-id "$session_id" "${claude_args[@]}")

exec claude "${claude_args[@]}" "$prompt"
