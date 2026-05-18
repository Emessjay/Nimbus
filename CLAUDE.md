# Nimbus — Claude project notes

## Auditor system

Nimbus *is* the auditor system: this repo holds the handbooks and
orchestration scripts that other agents read. If you are editing files
here, you are modifying that system.

If you were booted by `nimbus-audit` (env `NIMBUS_ROLE=auditor`), read
[AUDITOR.md](AUDITOR.md) — you are the supervisor and a PreToolUse hook
will block you from editing source code. If you were booted by
`nimbus-worker` inside a `nimbus-<slug>/` worktree of the home repo,
read [WORKER.md](WORKER.md) — you are a worker and report status via
`./scripts/worker-done.sh` and `./scripts/worker-blocked.sh`. If you
were spawned as a debugger, lightweight, or critic, read
[DEBUGGER.md](DEBUGGER.md), [LIGHTWEIGHT.md](LIGHTWEIGHT.md), or
[CRITIC.md](CRITIC.md) respectively. Either way, the rest of this
file still applies.

## Worktree-per-feature

Before starting work on any non-trivial feature, create a git worktree
for it and do all editing + testing inside that worktree.

When the feature is complete, commit the work *inside the worktree*
before handing off — do not leave uncommitted changes for the user to
merge, since a `git merge` of an unchanged branch is a no-op.

Alongside merge instructions, also give the user a command to exercise
the change end-to-end from the main worktree — the goal is for the user
to actually see the change working, not just confirm it compiles.

The primary reason is isolation between concurrent Claude instances:
working in a shared checkout means one instance can read another's
partially-written code mid-edit, leading to confused state and
conflicting changes. A worktree gives each instance its own filesystem
view and its own branch.

### Running tests inside a worktree

Because the Bash tool's working directory does not reliably persist
between calls, **always target the worktree explicitly** when running
tests, builds, or any command that depends on cwd — never assume a
previous `cd` is still in effect.

Use a single `cd … && …` invocation so the directory change and the
command are bound together in the same shell call. Worktrees live next
to the main checkout, so from the home repo's main directory the path
is `../<repo>-<slug>`.

Hand the user the same form — assume they're already in the home repo's
main directory rather than spelling out absolute paths.

Never split the `cd` and the command across two Bash tool calls — the
second call will silently run from the main worktree and pick up the
wrong sources.

### Merge conflicts

If a merge from `main` into your feature branch produces a conflict, do
**not** assume `main` looks the way it did when you branched — other
Claude instances may have landed features in parallel. Read both sides
of every conflict hunk carefully and preserve the new work on `main`
alongside your own changes. Resolving a conflict by discarding the
incoming side is almost never correct; when in doubt, inspect the
`main`-side commit (`git log -p` on the conflicting file) to understand
what feature it was implementing before deciding how to combine.
