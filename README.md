# Nimbus

Nimbus is a multi-agent orchestration layer for [Claude Code](https://claude.com/claude-code).
A long-lived **auditor** runs in tmux and supervises **workers**
(per-feature worktrees), **debuggers** (adversarial pair-reviewers), and
**lightweights** (quick scoped fixes) that it spawns to do the actual
coding. The auditor itself is forbidden from editing source by a
PreToolUse hook — its job is orchestration, not implementation.

The whole system is bash + markdown. No build step, no runtime
dependencies beyond the prerequisites below.

## Prerequisites

- **tmux** — the auditor, dashboard, and each worker run in their own
  tmux session/window. `brew install tmux` (macOS) or your distro's
  package manager.
- **[Claude Code](https://docs.claude.com/en/docs/claude-code/setup)** —
  the `claude` CLI must be on your `PATH`.
- **zsh or bash** — the shell wrappers in `scripts/nimbus-functions.sh`
  are POSIX-ish and work in either.
- **git** — workers operate in git worktrees.

## Install

1. Clone Nimbus anywhere on disk:

       git clone <this-repo-url> /path/to/Nimbus

2. Add the wrapper sourcing line to your shell rc with the absolute
   path you just cloned to:

       echo 'source /path/to/Nimbus/scripts/nimbus-functions.sh' >> ~/.zshrc
       source ~/.zshrc

3. Verify the wrappers loaded:

       type nimbus-audit
       # nimbus-audit is a shell function

The scripts derive `NIMBUS_HOME` from the location of
`nimbus-functions.sh` at source time, so Nimbus works no matter where
you cloned it.

## Workspace layout (suggested convention)

The recommended layout puts each project you orchestrate (a "home
repo") as a sibling of `Nimbus/` under a `<project>-workspace/`
directory — it keeps Nimbus, the home repo, and per-feature worktrees
all in one place:

    ~/Programs/
      nimbus-clone/
        Nimbus/                  # this repo (orchestration only)
      my-project-clone/
        my-project/              # a home repo
        my-project-<slug>/       # worker worktrees, created on demand

Nothing in the scripts enforces this layout — it's a convention, not a
requirement. The home repo has its own `CLAUDE.md`; Nimbus has the
role handbooks (`AUDITOR.md`, `WORKER.md`, `DEBUGGER.md`,
`LIGHTWEIGHT.md`, `CRITIC.md`) that every agent reads. When the
auditor bootstraps a fresh home repo it copies [TEMPLATE.md](TEMPLATE.md)
into the home repo's `CLAUDE.md`.

## Usage

From the home repo's directory, the shell wrappers give you:

| command             | what it does                                                                 |
| ------------------- | ---------------------------------------------------------------------------- |
| `nimbus-audit`      | Boot or attach the auditor in its tmux session. Pass an initial task string. |
| `nimbus-audit-stop` | Tear down the auditor session (orphan active workers).                       |
| `nimbus-dashboard`  | Live `list-workers.sh` view in a detachable tmux session.                    |
| `nimbus-worker-resume <slug>` | Resume an orphaned worker after auditor restart.                   |
| `nimbus` / `nimbus-continue` / `nimbus-resume` | Plain Claude Code session in the Nimbus repo, useful when editing the orchestration system itself. |

The auditor handles spawning, reviewing, merging, and cancelling
workers itself — you don't invoke `spawn-worker.sh` etc. directly.

Quick start:

    cd ~/Programs/Aletheia-workspace/Aletheia
    nimbus-audit "implement chapter export, fix dark-mode tab styling"

The auditor reads `AUDITOR.md`, splits the brief across one or more
agents, and reports back when each is done or blocked.

## Reading order

If you've just cloned the repo and want to understand how it works,
read in this order:

1. [CLAUDE.md](CLAUDE.md) — orientation for anyone (Claude or human) editing Nimbus itself
2. [AUDITOR.md](AUDITOR.md) — the supervisor handbook; the deepest doc
3. [WORKER.md](WORKER.md), [DEBUGGER.md](DEBUGGER.md), [LIGHTWEIGHT.md](LIGHTWEIGHT.md), [CRITIC.md](CRITIC.md) — the four agent roles
4. [TEMPLATE.md](TEMPLATE.md) — what gets dropped into a fresh home repo
5. `scripts/` — the bash glue (most files are <100 lines)
