#!/usr/bin/env bash
# Worktree helpers: worktree_create_at_base, worktree_create_with_integration,
# worktree_merge_parents, worktree_path_for_issue, worktree_branch_state_for_issue,
# _resolve_repo_root.
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
# Creates the worktree at $SENSIBLE_RALPH_DEFAULT_BASE_BRANCH (the per-repo trunk
# configured via .sensible-ralph.json, defaulting to "main"), then sequentially merges
# each parent branch. Callers must source lib/scope.sh before invoking this
# function so the env var is set; orchestrator.sh and dag_base.sh both do this
# via the conditional SENSIBLE_RALPH_SCOPE_LOADED gate.
# Conflict handling depends on parent count:
#   - Single parent: leaves conflicts in-place — the dispatched agent resolves
#     them. The `sr-implement` skill tells it to handle conflicts before
#     implementing the feature.
#   - Multi-parent: fails fast with `git merge --abort`. After a conflict on
#     parent N, git refuses subsequent merges (MERGING state). Returning 0
#     would leave the worktree with parent N's conflicts but parents N+1, N+2,
#     ... silently NOT merged — the dispatched agent has no signal that those
#     parents exist, so it would resolve N's conflicts and dispatch against an
#     incomplete integration. Failing fast forces the operator to resolve the
#     scope conflict (on the trunk branch, or by re-sequencing parents) before dispatch.
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

  git worktree add "$path" -b "$branch" "${SENSIBLE_RALPH_DEFAULT_BASE_BRANCH}"

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

# Merge a list of parent branches into the current HEAD of $path's worktree,
# in order. Skips parents already in ancestry (no-op merge). Conflict policy
# mirrors worktree_create_with_integration:
#   - single parent: leave conflicts in place for the agent to resolve, return 0
#   - multi-parent: abort and return non-zero so subsequent parents aren't
#     silently dropped
# Accepts either a local head or a remote-tracking ref under origin/ for each
# parent (matching worktree_create_at_base / _with_integration).
# $1: path     — worktree path (must already exist)
# $2+: parents — ordered list of parent branch names (zero is a no-op success)
worktree_merge_parents() {
  local path="$1"
  shift
  local parents=("$@")
  local parent_count="${#parents[@]}"
  if [ "$parent_count" -eq 0 ]; then
    return 0
  fi

  local resolved_refs=()
  local parent
  for parent in "${parents[@]}"; do
    if git -C "$path" show-ref --verify --quiet "refs/heads/$parent"; then
      resolved_refs+=("$parent")
    elif git -C "$path" show-ref --verify --quiet "refs/remotes/origin/$parent"; then
      resolved_refs+=("origin/$parent")
    else
      printf 'worktree_merge_parents: parent ref not found locally or under origin/: %s\n' "$parent" >&2
      return 1
    fi
  done

  local i merge_ref
  for (( i = 0; i < parent_count; i++ )); do
    merge_ref="${resolved_refs[$i]}"
    # Skip if already an ancestor — no-op merge.
    if git -C "$path" merge-base --is-ancestor "$merge_ref" HEAD 2>/dev/null; then
      continue
    fi
    git -C "$path" merge "$merge_ref" --no-edit && continue
    local unmerged
    unmerged="$(git -C "$path" diff --name-only --diff-filter=U)"
    if [[ -n "$unmerged" ]]; then
      if [[ "$parent_count" -eq 1 ]]; then
        return 0
      fi
      git -C "$path" merge --abort 2>/dev/null || true
      printf 'worktree_merge_parents: multi-parent merge conflict on %s — cannot continue (subsequent parents would be silently dropped). Resolve in main or re-sequence parents.\n' "$merge_ref" >&2
      return 1
    else
      printf 'worktree_merge_parents: merge failed for parent %s\n' "$merge_ref" >&2
      return 1
    fi
  done
}

# Resolve the true repo root (main checkout path) regardless of cwd.
# Returns the same path whether the caller's cwd is the main checkout, a
# linked worktree, or a subdirectory of either — --git-common-dir points at
# the shared .git directory, and its parent is the main checkout root.
# --path-format=absolute ensures an absolute path; without it git may return
# a relative ".git" when cwd is the repo root, making dirname return ".".
# Requires git >= 2.31.
#
# Known limitation: assumes the conventional "<root>/.git" layout. Repos
# using --separate-git-dir or checked out as git submodules have their
# gitdir at an unrelated location, and dirname would resolve to that
# unrelated parent rather than the working tree root. Ralph-start is a
# skill scoped to this repo (a standard checkout), so this case is not
# supported.
_resolve_repo_root() {
  local common_git
  common_git="$(git rev-parse --path-format=absolute --git-common-dir)" || return 1
  dirname "$common_git"
}

# Compute the worktree path for an issue given its branch name.
# Outputs: $REPO_ROOT/$CLAUDE_PLUGIN_OPTION_WORKTREE_BASE/<branch>
# Requires $CLAUDE_PLUGIN_OPTION_WORKTREE_BASE exported (set by the plugin harness).
worktree_path_for_issue() {
  local branch="$1"
  local repo_root
  repo_root="$(_resolve_repo_root)" || return 1
  local base="${CLAUDE_PLUGIN_OPTION_WORKTREE_BASE#/}"   # strip leading slash
  base="${base%/}"                                        # strip trailing slash
  printf '%s/%s/%s\n' "$repo_root" "$base" "$branch"
}

# Classify the per-issue (branch, worktree path) pair into one of:
#   both_exist            — branch exists AND worktree at $path is registered
#                           and checked out to $branch
#   neither               — branch absent AND $path absent
#   partial<TAB>branch-only         branch exists, no registered worktree at $path
#   partial<TAB>path-only           $path exists but branch does not
#   partial<TAB>path-not-worktree   $path exists but is not a registered git worktree
#   partial<TAB>wrong-branch        worktree at $path is checked out to a different branch
#
# Tab-separated output keeps callers bash 3.2-compatible:
#   output=$(worktree_branch_state_for_issue "$b" "$p")
#   state="${output%%$'\t'*}"     # "both_exist" | "neither" | "partial"
#   cause="${output#*$'\t'}"      # empty for both_exist/neither; non-empty for partial
worktree_branch_state_for_issue() {
  local branch="$1" path="$2"
  local branch_exists=0 worktree_for_branch=0 worktree_at_path_exists=0

  if git show-ref --verify --quiet "refs/heads/$branch"; then
    branch_exists=1
  fi

  # Use `git worktree list --porcelain` to detect both presence of $path as a
  # registered worktree AND whether it is checked out to $branch. A plain
  # `[ -e "$path" ]` check would admit stray directories and worktrees
  # checked out to unrelated branches.
  if [ -e "$path" ]; then
    worktree_at_path_exists=1
    if git worktree list --porcelain 2>/dev/null | awk -v p="$path" -v b="refs/heads/$branch" '
         /^worktree / { wpath = substr($0, 10) }
         $0 == "branch " b { if (wpath == p) { found = 1; exit } }
         END { exit (found ? 0 : 1) }
       '; then
      worktree_for_branch=1
    fi
  fi

  if [ "$branch_exists" -eq 1 ] && [ "$worktree_for_branch" -eq 1 ]; then
    printf 'both_exist\n'
  elif [ "$branch_exists" -eq 0 ] && [ "$worktree_at_path_exists" -eq 0 ]; then
    printf 'neither\n'
  elif [ "$branch_exists" -eq 1 ] && [ "$worktree_at_path_exists" -eq 0 ]; then
    printf 'partial\tbranch-only\n'
  elif [ "$branch_exists" -eq 0 ]; then
    # path exists (registered worktree or stray dir) but branch is absent
    printf 'partial\tpath-only\n'
  else
    # path exists, branch exists, but the registered worktree at $path is on a
    # different branch (or $path is a stray directory, not a registered worktree)
    if git worktree list --porcelain 2>/dev/null | awk -v p="$path" '
         /^worktree / { if (substr($0, 10) == p) { found = 1; exit } }
         END { exit (found ? 0 : 1) }
       '; then
      printf 'partial\twrong-branch\n'
    else
      printf 'partial\tpath-not-worktree\n'
    fi
  fi
}
