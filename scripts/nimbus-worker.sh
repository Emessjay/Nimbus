#!/usr/bin/env bash
# Boot a worker / debugger / lightweight Claude session inside a tmux window.
#
# Usage:
#   nimbus-worker.sh [--role worker|debugger|lightweight] <slug>
#
# Called by spawn-worker.sh, spawn-pair.sh, or spawn-lightweight.sh inside
# the tmux window it creates. Not typically invoked directly. Reads the
# task and pre-assigned session ID from .auditor-state/<slug>.state in
# the main repo (resolved via `git worktree list`) and execs claude.
#
# Role drives:
#   - which handbook the boot prompt points at (WORKER.md / DEBUGGER.md /
#     LIGHTWEIGHT.md)
#   - which verbs the boot prompt advertises (worker-done / debugger-approve / etc.)
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
    worker|debugger|lightweight) ;;
    *)
        echo "error: invalid role '$role' (must be worker|debugger|lightweight)" >&2
        exit 1
        ;;
esac

slug="${1:-}"
if [[ -z "$slug" ]]; then
    echo "usage: $0 [--role worker|debugger|lightweight] <slug>" >&2
    exit 1
fi

main_repo=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / { print $2; exit }')
if [[ -z "$main_repo" ]]; then
    echo "error: not inside a git repo" >&2
    exit 1
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

# Pick the session id field. Workers and lightweights use the canonical
# session_id; the debugger half of a pair uses debugger_session_id so the
# two halves of a paired feature have separate Claude sessions.
if [[ "$role" == "debugger" ]]; then
    session_id=$(awk '/^debugger_session_id=/ { print substr($0, index($0,"=")+1); exit }' "$state_file")
else
    session_id=$(awk '/^session_id=/ { print substr($0, index($0,"=")+1); exit }' "$state_file")
fi

# Construct the role-specific prompt.
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
        prompt="**read CLAUDE.md and WORKER.md before you start**

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
        prompt="**read CLAUDE.md and DEBUGGER.md before you act — you are the adversarial reviewer of one worker; you never edit code**

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
        prompt="**read CLAUDE.md and LIGHTWEIGHT.md before you act — you are a single-shot fixer for trivial changes**

Your slug: $slug
Your task:

$task

You are NOT in a worktree. You operate in the main checkout on branch
fix/$slug. Touch only the files the brief names. If the task is bigger
than a few lines or needs tests, stop and run:
    ./scripts/lightweight-blocked.sh \"scope grew, needs a worker\"

When done, commit on your fix/$slug branch and run:
    ./scripts/lightweight-done.sh \"<one-line summary>\"
The auditor will fast-forward your branch into main with
merge-lightweight.sh."
        ;;
esac

export NIMBUS_ROLE="$role"
export NIMBUS_WORKER_SLUG="$slug"

name_prefix="$role"
[[ "$role" == "worker" ]] && name_prefix="worker"

claude_args=(--effort "$effort" --name "$name_prefix:$slug")
[[ -n "$model" ]] && claude_args+=(--model "$model")
[[ -n "$session_id" ]] && claude_args=(--session-id "$session_id" "${claude_args[@]}")

exec claude "${claude_args[@]}" "$prompt"
