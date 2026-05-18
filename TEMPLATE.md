# {project name} — Claude project notes

## Auditor system

The agent role handbooks (`AUDITOR.md`, `WORKER.md`, `DEBUGGER.md`,
`LIGHTWEIGHT.md`, `CRITIC.md`) live in the **Nimbus orchestration
repo** — the same checkout this agent was booted from. Read Nimbus's
`CLAUDE.md` (resolvable via `$NIMBUS_HOME/CLAUDE.md`, or by following
the path that booted you) for the auditor-system orientation — it
links each role handbook and spells out the conventions agents follow.

If you were booted by `{project name}-audit` (env
`{project name}_ROLE=auditor`), you are the supervisor and a PreToolUse
hook will block you from editing source code. If you were booted by
`{project name}-worker` inside a `{project name}-<slug>/` worktree, you
are a worker and report status via `./scripts/worker-done.sh` and
`./scripts/worker-blocked.sh`. The Nimbus handbooks are written for a
generic "home repo" — this repo ({project name}) is the home repo;
project-specific hygiene lives in the rest of this file. Either way,
the rest of this file still applies.
