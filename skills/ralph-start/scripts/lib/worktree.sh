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
#
# Accepts either a local head or a remote-tracking ref under origin/. Fresh
# clones often have review parents present only via `git fetch` without local
# heads — passing the short name straight to `git worktree add` would fail to
# resolve in that case. Resolution is explicit (no DWIM) so the chosen ref
# is unambiguous in the error path.
worktree_create_at_base() {
  local path="$1" branch="$2" base="$3"
  local resolved_base
  if git show-ref --verify --quiet "refs/heads/$base"; then
    resolved_base="$base"
  elif git show-ref --verify --quiet "refs/remotes/origin/$base"; then
    resolved_base="origin/$base"
  else
    printf 'worktree_create_at_base: base ref not found locally or under origin/: %s\n' "$base" >&2
    return 1
  fi
  git worktree add "$path" -b "$branch" "$resolved_base"
}

# Create a worktree for integration (one or more parent branches in review).
# Creates the worktree at main, then sequentially merges each parent branch.
# Conflict handling depends on parent count:
#   - Single parent: leaves conflicts in-place — the dispatched agent resolves
#     them. The agent's prompt template tells it to handle conflicts before
#     implementing the feature.
#   - Multi-parent: fails fast with `git merge --abort`. After a conflict on
#     parent N, git refuses subsequent merges (MERGING state). Returning 0
#     would leave the worktree with parent N's conflicts but parents N+1, N+2,
#     ... silently NOT merged — the dispatched agent has no signal that those
#     parents exist, so it would resolve N's conflicts and dispatch against an
#     incomplete integration. Failing fast forces the operator to resolve the
#     scope conflict (in main, or by re-sequencing parents) before dispatch.
# $1: path      — absolute path where the worktree should be created
# $2: branch    — new branch name
# $3+: parents  — parent branches to merge sequentially
worktree_create_with_integration() {
  local path="$1" branch="$2"
  shift 2
  local parents=("$@")
  local parent_count="${#parents[@]}"

  # Validate all parent refs before creating any state. Accept either a local
  # head or a remote-tracking ref under origin/ — on a fresh clone, review
  # branches are typically present only via `git fetch` without a local head.
  # The resolved ref name (local short-name or "origin/<branch>") is recorded
  # in parallel so the merge step is unambiguous.
  local resolved_refs=()
  local parent
  for parent in "${parents[@]}"; do
    if git show-ref --verify --quiet "refs/heads/$parent"; then
      resolved_refs+=("$parent")
    elif git show-ref --verify --quiet "refs/remotes/origin/$parent"; then
      resolved_refs+=("origin/$parent")
    else
      printf 'worktree_create_with_integration: parent ref not found locally or under origin/: %s\n' "$parent" >&2
      return 1
    fi
  done

  git worktree add "$path" -b "$branch" main

  local i merge_ref
  for (( i = 0; i < parent_count; i++ )); do
    merge_ref="${resolved_refs[$i]}"
    git -C "$path" merge "$merge_ref" --no-edit && continue
    # Merge exited non-zero. Was it a conflict (expected) or something else (error)?
    local unmerged
    unmerged="$(git -C "$path" diff --name-only --diff-filter=U)"
    if [[ -n "$unmerged" ]]; then
      if [[ "$parent_count" -eq 1 ]]; then
        # Single parent: leave conflicts in place for the agent to resolve
        return 0
      fi
      # Multi-parent: abort and fail. Subsequent parents can't be silently dropped.
      git -C "$path" merge --abort 2>/dev/null || true
      printf 'worktree_create_with_integration: multi-parent merge conflict on %s — cannot continue (subsequent parents would be silently dropped). Resolve in main or re-sequence parents.\n' "$merge_ref" >&2
      return 1
    else
      printf 'worktree_create_with_integration: merge failed for parent %s\n' "$merge_ref" >&2
      return 1
    fi
  done
}

# Compute the worktree path for an issue given its branch name.
# Outputs: $REPO_ROOT/$RALPH_WORKTREE_BASE/<branch>
# Requires $RALPH_WORKTREE_BASE exported (set by config.sh).
# Resolves REPO_ROOT via --git-common-dir (the shared .git directory), so the
# result is the same whether the caller's cwd is the main checkout, a linked
# worktree, or a subdirectory of either. --show-toplevel would return the
# calling worktree's own root and cause new worktrees to nest under it.
# --path-format=absolute requires git >= 2.31.
worktree_path_for_issue() {
  local branch="$1"
  local common_git
  common_git="$(git rev-parse --path-format=absolute --git-common-dir)" || return 1
  local repo_root
  repo_root="$(dirname "$common_git")"
  local base="${RALPH_WORKTREE_BASE#/}"   # strip leading slash
  base="${base%/}"                         # strip trailing slash
  printf '%s/%s/%s\n' "$repo_root" "$base" "$branch"
}
