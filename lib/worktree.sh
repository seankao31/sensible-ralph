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
#
# Conflict handling: leaves conflicts in-place and returns 0. Writes a marker
# file at <path>/.sensible-ralph-pending-merges listing the FULL ORIGINAL
# parent list pinned to commit SHAs. The dispatched session reads the marker,
# resolves conflicts, completes the in-progress merge, and re-invokes
# worktree_merge_parents with the marker SHAs to drain remaining parents.
# See docs/design/worktree-contract.md "Pending parent merges".
#
# Each parent arg may be either a ref name (resolved against refs/heads then
# refs/remotes/origin) or a 40-char hex SHA. The helper resolves each to a
# (sha, display) tuple before merging; the marker write uses the SHAs so
# retries merge the same commits even if the named refs advance.
#
# $1: path      — absolute path where the worktree should be created
# $2: branch    — new branch name
# $3+: parents  — parent refs (or SHAs) to merge sequentially
worktree_create_with_integration() {
  local path="$1" branch="$2"
  shift 2
  local parents=("$@")
  local parent_count="${#parents[@]}"
  local marker_path="$path/.sensible-ralph-pending-merges"

  # Resolve each parent into a (sha, display) tuple. Worktree doesn't exist
  # yet, so resolution runs against the calling repo's git context — worktrees
  # share the object store, so the resolved SHAs are reachable from $path
  # once `git worktree add` runs.
  local resolved_shas=()
  local display_refs=()
  local arg sha display
  for arg in "${parents[@]}"; do
    if [[ "$arg" =~ ^[0-9a-f]{40}$ ]] && git cat-file -e "${arg}^{commit}" 2>/dev/null; then
      sha="$arg"
      display="$arg"
    elif git show-ref --verify --quiet "refs/heads/$arg"; then
      sha="$(git rev-parse "$arg")"
      display="$arg"
    elif git show-ref --verify --quiet "refs/remotes/origin/$arg"; then
      sha="$(git rev-parse "origin/$arg")"
      display="origin/$arg"
    else
      printf 'worktree_create_with_integration: parent ref not found: %s\n' "$arg" >&2
      return 1
    fi
    resolved_shas+=("$sha")
    display_refs+=("$display")
  done

  git worktree add "$path" -b "$branch" "${SENSIBLE_RALPH_DEFAULT_BASE_BRANCH}"

  local i
  for (( i = 0; i < parent_count; i++ )); do
    sha="${resolved_shas[$i]}"
    display="${display_refs[$i]}"
    # Skip if already an ancestor — re-runs after partial drain land here.
    if git -C "$path" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
      continue
    fi
    git -C "$path" merge "$sha" --no-edit && continue
    # Merge exited non-zero. Was it a conflict (expected) or something else (error)?
    local unmerged
    unmerged="$(git -C "$path" diff --name-only --diff-filter=U)"
    if [[ -n "$unmerged" ]]; then
      _worktree_write_pending_marker "$marker_path" resolved_shas display_refs
      return 0
    else
      printf 'worktree_create_with_integration: merge failed for parent %s\n' "$display" >&2
      return 1
    fi
  done

  # Clean drain — every parent merged or skipped via ancestor check. Remove
  # any prior marker (rm -f is safe whether the marker existed or not).
  rm -f "$marker_path"
  return 0
}

# Merge a list of parent branches into the current HEAD of $path's worktree,
# in order. Conflict semantics mirror worktree_create_with_integration: leaves
# conflicts in-place, writes the .sensible-ralph-pending-merges marker, and
# returns 0. The session resolves and re-invokes; idempotence comes from the
# in-loop ancestor-skip.
#
# Each parent arg may be a ref name (resolved against refs/heads then
# refs/remotes/origin) or a 40-char hex SHA — the latter is what the marker
# stores, so re-invocations with marker contents merge the same commits even
# if the named refs have advanced.
#
# Zero-parent invocation:
#   - marker absent → no-op success (return 0). The post-loop rm -f is a
#     no-op and the worktree is untouched.
#   - marker present → REFUSE (return 1). A stale marker from a prior failed
#     dispatch surfaces as orchestrator setup_failed rather than being
#     silently obliterated by a cleanup-only rm -f.
#
# $1: path     — worktree path (must already exist)
# $2+: parents — ordered list of parent refs / SHAs (zero-parent shape above)
worktree_merge_parents() {
  local path="$1"
  shift
  local parents=("$@")
  local parent_count="${#parents[@]}"
  local marker_path="$path/.sensible-ralph-pending-merges"

  # Marker-aware zero-parent guard. Defends against a session that derived
  # an empty SHA list from a corrupt marker and called the helper with no
  # args — which would otherwise hit the post-loop rm -f and silently drop
  # the pending list. Session-side strict marker validation is the primary
  # check (see /sr-implement Step 2); this is defense in depth.
  if [ "$parent_count" -eq 0 ] && [ -f "$marker_path" ]; then
    printf 'worktree_merge_parents: refusing zero-parent invocation while marker exists at %s\n' "$marker_path" >&2
    return 1
  fi

  # Resolve each parent into a (sha, display) tuple.
  local resolved_shas=()
  local display_refs=()
  local arg sha display
  for arg in "${parents[@]}"; do
    if [[ "$arg" =~ ^[0-9a-f]{40}$ ]] && git -C "$path" cat-file -e "${arg}^{commit}" 2>/dev/null; then
      sha="$arg"
      display="$arg"
    elif git -C "$path" show-ref --verify --quiet "refs/heads/$arg"; then
      sha="$(git -C "$path" rev-parse "$arg")"
      display="$arg"
    elif git -C "$path" show-ref --verify --quiet "refs/remotes/origin/$arg"; then
      sha="$(git -C "$path" rev-parse "origin/$arg")"
      display="origin/$arg"
    else
      printf 'worktree_merge_parents: parent ref not found: %s\n' "$arg" >&2
      return 1
    fi
    resolved_shas+=("$sha")
    display_refs+=("$display")
  done

  local i
  for (( i = 0; i < parent_count; i++ )); do
    sha="${resolved_shas[$i]}"
    display="${display_refs[$i]}"
    if git -C "$path" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
      continue
    fi
    git -C "$path" merge "$sha" --no-edit && continue
    local unmerged
    unmerged="$(git -C "$path" diff --name-only --diff-filter=U)"
    if [[ -n "$unmerged" ]]; then
      _worktree_write_pending_marker "$marker_path" resolved_shas display_refs
      return 0
    else
      printf 'worktree_merge_parents: merge failed for parent %s\n' "$display" >&2
      return 1
    fi
  done

  rm -f "$marker_path"
  return 0
}

# Write the .sensible-ralph-pending-merges marker file. Each line is
# "<sha> <display>" — the SHA is the authoritative pinning, the display ref
# is informational for log readability. The marker captures the caller's
# COMPLETE original parent list (including parents already skipped via the
# ancestor check this run), in original order.
#
# Args (all required):
#   $1               marker file path
#   $2 (nameref)     name of the resolved-SHAs array
#   $3 (nameref)     name of the display-refs array
#
# Bash 4.3+ namerefs (`local -n`) are not available in bash 3.2 (macOS
# default), so we eval the array expansions explicitly.
_worktree_write_pending_marker() {
  local marker_path="$1"
  local shas_var="$2"
  local displays_var="$3"
  local count
  eval "count=\${#${shas_var}[@]}"
  local i sha display
  : > "$marker_path"
  for (( i = 0; i < count; i++ )); do
    eval "sha=\${${shas_var}[\$i]}"
    eval "display=\${${displays_var}[\$i]}"
    printf '%s %s\n' "$sha" "$display" >> "$marker_path"
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
