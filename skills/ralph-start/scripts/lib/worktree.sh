#!/usr/bin/env bash
# Worktree creation helpers: worktree_create_at_base, worktree_create_with_integration,
# worktree_path_for_issue.
#
# Callers run with set -euo pipefail; do NOT call set at the top level here.
# Use `return` for errors, not `exit`.

# Create a worktree at a simple base (main or a parent branch).
# $1: path   — absolute path where the worktree should be created
# $2: branch — new branch name to create
# $3: base   — the base ref to branch from (e.g. "main" or "eng-XXX-parent")
worktree_create_at_base() {
  local path="$1" branch="$2" base="$3"
  git worktree add "$path" -b "$branch" "$base"
}

# Create a worktree for integration (multiple parent branches in review).
# Creates the worktree at main, then sequentially merges each parent branch.
# On merge conflict: leaves conflicts in-place — the dispatched agent resolves them.
# $1: path      — absolute path where the worktree should be created
# $2: branch    — new branch name
# $3+: parents  — parent branches to merge sequentially
worktree_create_with_integration() {
  local path="$1" branch="$2"
  shift 2
  local parents=("$@")

  git worktree add "$path" -b "$branch" main

  for parent in "${parents[@]}"; do
    git -C "$path" show-ref --verify --quiet "refs/heads/$parent" || {
      printf 'worktree_create_with_integration: parent ref not found: %s\n' "$parent" >&2
      return 1
    }
    # Conflicts are intentionally left in-place; do not propagate merge exit code.
    git -C "$path" merge "$parent" --no-edit || true
  done
}

# Compute the worktree path for an issue given its branch name.
# Outputs: $REPO_ROOT/$RALPH_WORKTREE_BASE/<branch>
# Requires $RALPH_WORKTREE_BASE exported (set by config.sh).
# Detects REPO_ROOT via git rev-parse --show-toplevel.
worktree_path_for_issue() {
  local branch="$1"
  local repo_root
  repo_root="$(git rev-parse --show-toplevel)" || return 1
  local base="${RALPH_WORKTREE_BASE#/}"   # strip leading slash
  base="${base%/}"                         # strip trailing slash
  printf '%s/%s/%s\n' "$repo_root" "$base" "$branch"
}
