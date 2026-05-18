#!/usr/bin/env bash
# Create a git worktree for a new feature and install its node_modules.
# See the "Worktree-per-feature" section in CLAUDE.md for context.
#
# Usage:
#   ./scripts/new-worktree.sh <slug>
#
# Creates ../nimbus-<slug> on branch feature/<slug>, then runs `npm install`
# inside it.

set -euo pipefail

if [[ $# -ne 1 || -z "${1:-}" ]]; then
    echo "usage: $0 <slug>" >&2
    exit 1
fi

slug="$1"
repo_root="$(git rev-parse --show-toplevel)"
worktree_path="${repo_root%/*}/nimbus-${slug}"
branch="feature/${slug}"

if [[ -e "$worktree_path" ]]; then
    echo "error: $worktree_path already exists" >&2
    exit 1
fi

git -C "$repo_root" worktree add "$worktree_path" -b "$branch"

# Copy the bundled SQLite corpus into the worktree. The DB is gitignored
# (~200MB) so `worktree add` doesn't bring it across, but the app and its
# ingest scripts expect it at data/Nimbus.sqlite. `cp -c` uses APFS
# clonefile, so this is effectively free on disk and instant.
db_src="${repo_root}/data/Nimbus.sqlite"
db_dst="${worktree_path}/data/Nimbus.sqlite"
if [[ -f "$db_src" ]]; then
    mkdir -p "$(dirname "$db_dst")"
    cp -c "$db_src" "$db_dst" 2>/dev/null || cp "$db_src" "$db_dst"
fi

cd "$worktree_path"
npm install

echo
echo "Worktree ready: $worktree_path (branch $branch)"
