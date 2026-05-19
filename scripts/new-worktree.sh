#!/usr/bin/env bash
# Create a git worktree for a new feature. If the new worktree contains a
# package.json, npm install is run; if it contains scripts/post-worktree.sh,
# that hook is sourced. Otherwise the worktree is created and left alone.
# See the "Worktree-per-feature" section in CLAUDE.md for context.
#
# Usage:
#   ./scripts/new-worktree.sh <slug>
#
# Creates <home_repo_path>-<slug> (sibling of the main checkout) on
# branch feature/<slug>.

set -euo pipefail

if [[ $# -ne 1 || -z "${1:-}" ]]; then
    echo "usage: $0 <slug>" >&2
    exit 1
fi

slug="$1"
repo_root="$(git rev-parse --show-toplevel)"
worktree_path="${repo_root}-${slug}"
branch="feature/${slug}"

if [[ -e "$worktree_path" ]]; then
    echo "error: $worktree_path already exists" >&2
    exit 1
fi

git -C "$repo_root" worktree add "$worktree_path" -b "$branch"

cd "$worktree_path"

if [[ -f package.json ]]; then
    npm install
    echo
    echo "npm install complete."
fi

if [[ -f scripts/post-worktree.sh ]]; then
    source scripts/post-worktree.sh
fi

echo
echo "Worktree ready: $worktree_path (branch $branch)"
