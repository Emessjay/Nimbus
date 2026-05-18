# Nimbus shell functions for the auditor / worker system.
#
# Source this from your ~/.zshrc:
#
#     source ~/Programs/Nimbus-workspace/Nimbus/scripts/nimbus-functions.sh
#
# The existing `nimbus` / `nimbus-continue` / `nimbus-resume`
# helpers from the old setup are preserved here so you can replace any
# ad-hoc definitions in your dotfiles with a single source line.

# -- existing wrappers (kept for backwards compatibility) ---------------

# Boot a regular Claude Code session in the main Nimbus checkout with
# the CLAUDE.md hygiene reminder prepended.
#   nimbus                    # just the hygiene prompt
#   nimbus "implement X"      # hygiene + task
nimbus() {
    cd ~/Programs/Nimbus-workspace/Nimbus || return
    claude "**read CLAUDE.md before you code for essential hygiene instructions**

$*"
}

nimbus-continue() { cd ~/Programs/Nimbus-workspace/Nimbus && claude --continue; }
nimbus-resume()   { cd ~/Programs/Nimbus-workspace/Nimbus && claude --resume;   }

# -- dashboard ----------------------------------------------------------

# Open a live dashboard of worker state in its own tmux session.
# Re-runs list-workers.sh every 2 seconds via `watch`. Detach with
# Ctrl-b d; the session keeps running in the background.
#
#   nimbus-dashboard
nimbus-dashboard() {
    if ! command -v tmux >/dev/null 2>&1; then
        echo "error: tmux is not installed. Install with: brew install tmux" >&2
        return 1
    fi
    local session="nimbus-dashboard"
    if tmux has-session -t "$session" 2>/dev/null; then
        tmux attach -t "$session"
    else
        local script='cd ~/Programs/Nimbus-workspace/Nimbus && while true; do clear; ./scripts/list-workers.sh --all; sleep 2; done'
        tmux new-session -s "$session" "bash -c $(printf '%q' "$script")"
    fi
}

# -- auditor mode -------------------------------------------------------

# Boot or attach to the auditor. The auditor runs inside a dedicated
# tmux session (`nimbus-auditor`) so worker/debugger/lightweight
# scripts can push wake-up prompts into it via tmux send-keys when
# state changes — no more polling latency. Closing your terminal does
# not kill the auditor; reattach by running nimbus-audit again.
#
#   nimbus-audit                                  # boot or attach
#   nimbus-audit "add chapter export, fix search" # boot + initial task
#
# If the tmux session already exists, the initial task argument is
# ignored — you can pass any task message via the live claude prompt.
nimbus-audit() {
    cd ~/Programs/Nimbus-workspace/Nimbus || return
    if ! command -v tmux >/dev/null 2>&1; then
        echo "error: tmux is not installed. Install with: brew install tmux" >&2
        return 1
    fi
    local session="nimbus-auditor"
    if tmux has-session -t "$session" 2>/dev/null; then
        tmux attach -t "$session"
        return
    fi
    local task="$*"
    local prompt='**read AUDITOR.md before you act — you orchestrate other agents, you do not code yourself**

Worker/debugger/lightweight scripts will push wake-up prompts into
your tmux window the instant their state changes, so all reactions
happen via prompts arriving on their own. The UserPromptSubmit notify
hook diffs .auditor-state against .notify-seen on every turn, so any
transition a push missed is surfaced on the next prompt regardless.
Do not chat with the user when there is no orchestration work to do —
end the turn silently and wait for the next push wake-up.'
    if [[ -n "$task" ]]; then
        prompt="$prompt

Initial task: $task"
    fi
    # Launch claude inside a new tmux session and attach. When claude
    # exits (e.g. /exit), the SessionEnd hook fires before the process
    # dies, cleaning up workers; then the tmux window closes.
    tmux new-session -A -s "$session" -n auditor -e NIMBUS_ROLE=auditor \
        claude --effort high --name auditor "$prompt"
}

# Resume the most recent auditor session, re-creating the tmux session.
# Used when the auditor's claude process exited (via /exit or kill) but
# you want to continue the prior conversation.
nimbus-audit-resume() {
    cd ~/Programs/Nimbus-workspace/Nimbus || return
    if ! command -v tmux >/dev/null 2>&1; then
        echo "error: tmux is not installed. Install with: brew install tmux" >&2
        return 1
    fi
    local session="nimbus-auditor"
    if tmux has-session -t "$session" 2>/dev/null; then
        echo "auditor session already running; attaching."
        tmux attach -t "$session"
        return
    fi
    tmux new-session -A -s "$session" -n auditor -e NIMBUS_ROLE=auditor \
        claude --effort high --name auditor --continue
}

# Kill the auditor and all its subagents (workers, debuggers, lightweights).
# Active workers are marked orphaned so their worktrees + commits +
# session_ids survive — you can revive them with nimbus-worker-resume
# after relaunching the auditor. Pass --hard to additionally tear down
# worktrees and feature branches (destructive; the equivalent of cancel
# for everyone).
#
#   nimbus-audit-stop           soft: orphan active workers, kill tmux
#   nimbus-audit-stop --hard    hard: cancel everyone, then kill tmux
nimbus-audit-stop() {
    cd ~/Programs/Nimbus-workspace/Nimbus || return
    local hard=0
    [[ "${1:-}" == "--hard" ]] && hard=1

    local state_dir="$PWD/.auditor-state"
    if [[ -d "$state_dir" ]]; then
        local now sf slug state
        now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        shopt -s nullglob
        for sf in "$state_dir"/*.state; do
            state=$(grep '^state=' "$sf" | head -1 | cut -d= -f2-)
            slug=$(grep '^slug=' "$sf" | head -1 | cut -d= -f2-)
            [[ "$state" != "running" && "$state" != "blocked" ]] && continue
            if (( hard )); then
                "$PWD/scripts/cancel-worker.sh" "$slug" >/dev/null 2>&1 || true
            else
                local tmp
                tmp=$(mktemp)
                while IFS= read -r line; do
                    case "$line" in
                        state=*)      echo "state=orphaned" ;;
                        updated_at=*) echo "updated_at=$now" ;;
                        *)            echo "$line" ;;
                    esac
                done < "$sf" > "$tmp"
                mv "$tmp" "$sf"
            fi
        done
        shopt -u nullglob
    fi

    if command -v tmux >/dev/null 2>&1; then
        tmux kill-session -t nimbus-workers 2>/dev/null || true
        tmux kill-session -t nimbus-auditor 2>/dev/null || true
    fi

    if (( hard )); then
        echo "auditor stopped (hard): all subagents cancelled, tmux sessions killed."
    else
        echo "auditor stopped: active subagents marked orphaned, tmux sessions killed."
        echo "  reboot with: nimbus-audit"
        echo "  then revive workers with: nimbus-worker-resume <slug>"
    fi
}

# -- worker mode --------------------------------------------------------
#
# Workers are spawned by scripts/spawn-worker.sh, which boots them in a
# detached tmux session named "nimbus-workers" (one window per slug).
# The boot itself is handled by scripts/nimbus-worker.sh — it does not
# need to be a shell function because tmux can exec it directly.
#
# Attach to see all live workers:   tmux attach -t nimbus-workers
#
# `nimbus-worker-resume` (below) revives a worker whose tmux window
# has closed, optionally delivering the auditor's queued mailbox content
# and any inline message as its first prompt of the new session.
nimbus-worker-resume() {
    local slug="$1"
    shift
    local msg="$*"

    if [[ -z "$slug" ]]; then
        echo "usage: nimbus-worker-resume <slug> [message]" >&2
        return 1
    fi

    if ! command -v tmux >/dev/null 2>&1; then
        echo "error: tmux is not installed. Install with: brew install tmux" >&2
        return 1
    fi

    local main_repo
    main_repo=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / { print $2; exit }')
    [[ -z "$main_repo" ]] && main_repo="$HOME/Programs/Nimbus-workspace/Nimbus"

    local state_file="$main_repo/.auditor-state/$slug.state"
    if [[ ! -f "$state_file" ]]; then
        echo "error: no state for $slug" >&2
        return 1
    fi

    local worktree_path session_id mailbox queued effort
    worktree_path=$(grep '^worktree_path=' "$state_file" | head -1 | cut -d= -f2-)
    session_id=$(grep '^session_id=' "$state_file" | head -1 | cut -d= -f2-)
    effort=$(grep '^effort=' "$state_file" | head -1 | cut -d= -f2-)
    effort="${effort:-medium}"
    mailbox="$main_repo/.auditor-state/$slug.mailbox"

    if [[ -z "$session_id" ]]; then
        echo "error: no session_id recorded for $slug; cannot resume" >&2
        return 1
    fi
    if [[ ! -d "$worktree_path" ]]; then
        echo "error: worktree $worktree_path is gone; was it merged?" >&2
        return 1
    fi

    # Drain mailbox; if non-empty, prepend it to the resume prompt.
    queued=""
    if [[ -s "$mailbox" ]]; then
        queued=$(cat "$mailbox")
        rm -f "$mailbox"
    fi

    local prompt=""
    if [[ -n "$queued" && -n "$msg" ]]; then
        prompt="(queued mailbox)

$queued

(new message)

$msg"
    elif [[ -n "$queued" ]]; then
        prompt="(queued mailbox)

$queued"
    elif [[ -n "$msg" ]]; then
        prompt="$msg"
    fi

    # If a tmux window for this slug already exists (rare — usually the
    # caller checked first), refuse rather than collide.
    local tmux_session="nimbus-workers"
    if tmux list-windows -t "$tmux_session" -F "#{window_name}" 2>/dev/null \
         | grep -qx "$slug"; then
        echo "error: tmux window $tmux_session:$slug already exists" >&2
        echo "       attach with: tmux attach -t $tmux_session"        >&2
        return 1
    fi

    # Build the claude command. Quote the prompt only if non-empty; an
    # empty prompt would leave the worker idle at its previous state,
    # which is fine. Prepend NIMBUS_ROLE=worker so the worker-side
    # PreToolUse hooks (worker-no-orchestration-bash.sh) fire.
    local cmd
    local env_prefix="NIMBUS_ROLE=worker NIMBUS_WORKER_SLUG=$(printf '%q' "$slug")"
    if [[ -n "$prompt" ]]; then
        cmd="$env_prefix claude --resume $(printf '%q' "$session_id") --effort $(printf '%q' "$effort") --name $(printf '%q' "worker:$slug") $(printf '%q' "$prompt")"
    else
        cmd="$env_prefix claude --resume $(printf '%q' "$session_id") --effort $(printf '%q' "$effort") --name $(printf '%q' "worker:$slug")"
    fi

    if tmux has-session -t "$tmux_session" 2>/dev/null; then
        tmux new-window -t "$tmux_session:" -n "$slug" -c "$worktree_path" "$cmd"
    else
        tmux new-session -d -s "$tmux_session" -n "$slug" -c "$worktree_path" "$cmd"
    fi

    echo "resumed worker $slug in tmux."
    echo "attach with: tmux attach -t $tmux_session"
}
