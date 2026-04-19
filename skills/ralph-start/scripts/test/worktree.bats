#!/usr/bin/env bats
# Tests for scripts/lib/worktree.sh
# Uses a real throwaway git repo — no mocked git commands.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
WORKTREE_SH="$SCRIPT_DIR/lib/worktree.sh"

setup() {
  REPO_DIR="$(cd "$(mktemp -d)" && pwd -P)"
  git -C "$REPO_DIR" init
  git -C "$REPO_DIR" config user.email "test@test.com"
  git -C "$REPO_DIR" config user.name "Test"
  # Create an initial commit so main branch exists
  touch "$REPO_DIR/README.md"
  git -C "$REPO_DIR" add README.md
  git -C "$REPO_DIR" commit -m "init"

  # Export RALPH_WORKTREE_BASE as config.sh would
  export RALPH_WORKTREE_BASE=".worktrees"
}

teardown() {
  rm -rf "$REPO_DIR"
}

# ---------------------------------------------------------------------------
# Helper: source worktree.sh and call a function in a subshell
# ---------------------------------------------------------------------------
call_fn() {
  local fn_name="$1"; shift
  # Run from inside the repo so git rev-parse --show-toplevel resolves correctly
  bash -c "cd '$REPO_DIR' && source '$WORKTREE_SH' && $fn_name $(printf '%q ' "$@")"
}

# ---------------------------------------------------------------------------
# 1. worktree_create_at_base — creates a worktree at the given path on a new branch
# ---------------------------------------------------------------------------
@test "worktree_create_at_base creates worktree directory at the given path" {
  local wt_path="$REPO_DIR/.worktrees/feature-abc"

  run call_fn worktree_create_at_base "$wt_path" "feature-abc" "main"

  [ "$status" -eq 0 ]
  [ -d "$wt_path" ]
}

@test "worktree_create_at_base creates worktree on the specified new branch" {
  local wt_path="$REPO_DIR/.worktrees/feature-xyz"

  call_fn worktree_create_at_base "$wt_path" "feature-xyz" "main"

  run git -C "$wt_path" branch --show-current
  [ "$status" -eq 0 ]
  [ "$output" = "feature-xyz" ]
}

# ---------------------------------------------------------------------------
# 2. worktree_create_with_integration — clean merge brings parent content in
# ---------------------------------------------------------------------------
@test "worktree_create_with_integration merges parent content into worktree" {
  # Create a parent branch with a unique file
  git -C "$REPO_DIR" checkout -b "eng-10-parent"
  echo "parent content" > "$REPO_DIR/parent_file.txt"
  git -C "$REPO_DIR" add parent_file.txt
  git -C "$REPO_DIR" commit -m "add parent file"
  git -C "$REPO_DIR" checkout main

  local wt_path="$REPO_DIR/.worktrees/integration-branch"

  run call_fn worktree_create_with_integration "$wt_path" "integration-branch" "eng-10-parent"

  [ "$status" -eq 0 ]
  [ -d "$wt_path" ]
  [ -f "$wt_path/parent_file.txt" ]
}

# ---------------------------------------------------------------------------
# 3. worktree_create_with_integration — conflict left in-place, not aborted
# ---------------------------------------------------------------------------
@test "worktree_create_with_integration leaves merge conflicts in-place" {
  # Branch from initial commit so both main and parent independently add the same
  # file — this creates an add/add conflict that git cannot auto-resolve.
  git -C "$REPO_DIR" checkout -b "eng-11-conflicting"
  echo "parent version" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "parent adds conflict.txt"
  git -C "$REPO_DIR" checkout main

  echo "main version" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "main adds conflict.txt"

  local wt_path="$REPO_DIR/.worktrees/conflicting-integration"

  # This must NOT fail even though there is a conflict
  run call_fn worktree_create_with_integration "$wt_path" "conflicting-integration" "eng-11-conflicting"

  [ "$status" -eq 0 ]
  [ -d "$wt_path" ]
  # Conflict marker in git status: UU or AA
  run git -C "$wt_path" status --porcelain
  [[ "$output" =~ ^(UU|AA) ]]
}

# ---------------------------------------------------------------------------
# 4. worktree_path_for_issue — computes the correct path from repo root
# ---------------------------------------------------------------------------
@test "worktree_path_for_issue returns correct path for a branch name" {
  local expected="$REPO_DIR/$RALPH_WORKTREE_BASE/eng-99-some-feature"

  run call_fn worktree_path_for_issue "eng-99-some-feature"

  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}
