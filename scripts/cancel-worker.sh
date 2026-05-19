#!/usr/bin/env bash
# Cancel an agent: kill its tmux window(s) and tear down its working
# state. Per-role details:
#
#   worker / pair  — force-remove the worktree, force-delete the branch.
#                    Uncommitted and committed work on the feature branch
#                    is lost.
#   critic         — no worktree, no branch; clean up archived critique
#                    and screenshots.
#   lightweight    — no branch to delete (lightweights commit directly
#                    to `main`). Revert the lightweight's commits with
#                    `git revert $start_sha..HEAD` so history records
#                    the undo without rewriting; surfaces any conflict
#                    rather than silently discarding work.
#
# In every case, before tearing anything down: if the main checkout has
# uncommitted edits, stash them under `cancelled-<slug>-WIP` so they
# remain recoverable. The state file is preserved as a record
# (state=cancelled).
#
# Usage:
#   ./scripts/cancel-worker.sh <slug>

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <slug>" >&2
    exit 1
fi

slug="$1"
repo_root="$(git rev-parse --show-toplevel)"
state_dir="$repo_root/.auditor-state"
state_file="$state_dir/$slug.state"

if [[ ! -f "$state_file" ]]; then
    echo "error: no state for $slug" >&2
    exit 1
fi

worktree_path=$(grep '^worktree_path=' "$state_file" | head -1 | cut -d= -f2-)
# branch may be absent (critics have no branch); tolerate via || true.
branch=$(grep '^branch=' "$state_file" | head -1 | cut -d= -f2- || true)
state=$(grep '^state=' "$state_file" | head -1 | cut -d= -f2-)
role=$(grep '^role=' "$state_file" | head -1 | cut -d= -f2-)
role="${role:-worker}"
pair_mode=$(grep '^pair_mode=' "$state_file" | head -1 | cut -d= -f2- || true)
start_sha=$(grep '^start_sha=' "$state_file" | head -1 | cut -d= -f2- || true)

if [[ "$state" == "merged" ]]; then
    echo "error: $role $slug was already merged; nothing to cancel" >&2
    exit 1
fi

# Stash any uncommitted edits in the main checkout. A dying agent
# (especially a lightweight, which operates in the main checkout) can
# leave WIP that would otherwise be silently lost — branch teardown
# below doesn't see uncommitted state. The stash is recoverable via
# `git stash list` / `git stash apply`.
wip_stash_msg="cancelled-$slug-WIP"
wip_stashed=0
if ! git -C "$repo_root" diff --quiet \
   || ! git -C "$repo_root" diff --cached --quiet \
   || [[ -n "$(git -C "$repo_root" ls-files --others --exclude-standard)" ]]; then
    if git -C "$repo_root" stash push --include-untracked -m "$wip_stash_msg" >/dev/null 2>&1; then
        wip_stashed=1
    fi
fi

# Kill the agent's tmux window(s) if alive. Workers use the bare slug;
# lightweights add -light; critics add -crit; debuggers in a pair add -dbg.
if command -v tmux >/dev/null 2>&1; then
    case "$role" in
        lightweight)
            tmux kill-window -t "nimbus-workers:${slug}-light" 2>/dev/null || true
            ;;
        critic)
            tmux kill-window -t "nimbus-workers:${slug}-crit" 2>/dev/null || true
            ;;
        *)
            tmux kill-window -t "nimbus-workers:$slug" 2>/dev/null || true
            if [[ "$pair_mode" == "paired" ]]; then
                tmux kill-window -t "nimbus-workers:${slug}-dbg" 2>/dev/null || true
            fi
            ;;
    esac
fi

revert_status="skipped"
if [[ "$role" == "lightweight" ]]; then
    # Lightweight commits directly to main — no branch to delete, no
    # worktree to remove. Undo any commits the lightweight authored
    # with `git revert` so the history is preserved and the undo is
    # itself a real commit.
    if [[ -z "$start_sha" ]]; then
        echo "warning: no start_sha recorded for lightweight $slug; cannot auto-revert." >&2
        echo "         (state file pre-dates lightweight-no-branch refactor.)" >&2
        revert_status="no-start-sha"
    else
        head_sha=$(git -C "$repo_root" rev-parse HEAD)
        if [[ "$head_sha" == "$start_sha" ]]; then
            revert_status="no-commits"
        else
            if git -C "$repo_root" revert --no-edit "$start_sha..HEAD" >/dev/null 2>&1; then
                revert_status="reverted"
            else
                git -C "$repo_root" revert --abort >/dev/null 2>&1 || true
                echo "error: cancel could not auto-revert lightweight $slug; resolve manually." >&2
                echo "       range: $start_sha..HEAD" >&2
                revert_status="conflict"
            fi
        fi
    fi
elif [[ "$role" == "critic" ]]; then
    # Critic has no worktree and no branch — it observes only. Remove
    # the archived critique and screenshots so the slug is truly clean.
    rm -f "$state_dir/$slug.critique.md"
    rm -rf "$state_dir/$slug.screenshots"
    rm -f "$state_dir/$slug.critique.log"
else
    # Force-remove the worktree (uncommitted changes are discarded).
    if [[ -d "$worktree_path" ]]; then
        git -C "$repo_root" worktree remove --force "$worktree_path" 2>/dev/null || true
    fi
    # Force-delete the branch.
    git -C "$repo_root" branch -D "$branch" 2>/dev/null || true
fi

# Mark state cancelled.
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp)
while IFS= read -r line; do
    case "$line" in
        state=*)      echo "state=cancelled" ;;
        updated_at=*) echo "updated_at=$now" ;;
        *)            echo "$line" ;;
    esac
done < "$state_file" > "$tmp"
mv "$tmp" "$state_file"

# Drop the mailbox.
rm -f "$state_dir/$slug.mailbox"

echo "cancelled $role $slug:"
case "$role" in
    lightweight)
        echo "  - killed tmux window nimbus-workers:${slug}-light"
        case "$revert_status" in
            reverted)     echo "  - reverted commits $start_sha..HEAD on main" ;;
            no-commits)   echo "  - no commits to revert (HEAD == start_sha)" ;;
            conflict)     echo "  - REVERT FAILED — resolve manually before reusing this slug" ;;
            no-start-sha) echo "  - no start_sha recorded; commits (if any) left on main" ;;
            *)            echo "  - revert: $revert_status" ;;
        esac
        ;;
    critic)
        echo "  - killed tmux window nimbus-workers:${slug}-crit"
        echo "  - removed archived critique and screenshots"
        ;;
    *)
        echo "  - killed tmux window nimbus-workers:$slug"
        [[ "$pair_mode" == "paired" ]] && echo "  - killed tmux window nimbus-workers:${slug}-dbg"
        echo "  - force-removed worktree $worktree_path"
        echo "  - force-deleted branch $branch"
        ;;
esac
if (( wip_stashed )); then
    echo "  - stashed uncommitted WIP as '$wip_stash_msg' (recover via: git stash list)"
fi
echo "  - mailbox cleared, state set to cancelled"
echo
case "$role" in
    lightweight) echo "respawn with: ./scripts/spawn-lightweight.sh $slug \"<reformulated task>\"" ;;
    critic)      echo "respawn with: ./scripts/spawn-critic.sh $slug \"<reformulated task>\"" ;;
    *)           echo "respawn with: ./scripts/spawn-worker.sh $slug \"<reformulated task>\"" ;;
esac
