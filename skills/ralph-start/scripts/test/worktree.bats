#!/usr/bin/env bats
# Tests for scripts/lib/worktree.sh
# Uses a real throwaway git repo — no mocked git commands.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
WORKTREE_SH="$SCRIPT_DIR/lib/worktree.sh"

setup() {
  REPO_DIR="$(cd "$(mktemp -d)" && pwd -P)"
  git -C "$REPO_DIR" init -b main
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

# Like call_fn but runs from a caller-specified working directory.
call_fn_from() {
  local cwd="$1" fn_name="$2"; shift 2
  CWD_OVERRIDE="$cwd" bash -c "cd \"\$CWD_OVERRIDE\" && source '$WORKTREE_SH' && $fn_name $(printf '%q ' "$@")"
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

@test "worktree_path_for_issue strips leading and trailing slashes from RALPH_WORKTREE_BASE" {
  local expected="$REPO_DIR/.worktrees/eng-99-slash-test"

  run bash -c "cd '$REPO_DIR' && RALPH_WORKTREE_BASE='/.worktrees/' source '$WORKTREE_SH' && worktree_path_for_issue eng-99-slash-test"

  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

# ---------------------------------------------------------------------------
# 5. worktree_path_for_issue — returns non-zero when cwd has no git repo
# ---------------------------------------------------------------------------
@test "worktree_path_for_issue fails when run from a non-git directory" {
  local no_git_dir
  no_git_dir="$(mktemp -d)"

  run call_fn_from "$no_git_dir" worktree_path_for_issue "eng-99-no-git"

  [ "$status" -ne 0 ]

  rm -rf "$no_git_dir"
}

# ---------------------------------------------------------------------------
# 5b. worktree_create_with_integration — accept parent that exists only as
#     a remote-tracking ref (cross-machine usage: branches fetched from origin
#     without local heads). Codex review: the local-heads-only check rejected
#     valid integration parents on fresh clones.
# ---------------------------------------------------------------------------
@test "worktree_create_with_integration accepts parent present only as remote tracking ref" {
  # Build a parent commit, capture its SHA, then synthesize a remote-tracking
  # ref by deleting the local branch and writing refs/remotes/origin/<branch>
  # directly. This mimics the post-fetch state without needing a real remote.
  git -C "$REPO_DIR" checkout -b "eng-50-remote-parent"
  echo "remote-only parent content" > "$REPO_DIR/remote-only.txt"
  git -C "$REPO_DIR" add remote-only.txt
  git -C "$REPO_DIR" commit -m "remote-only parent"
  local parent_sha; parent_sha="$(git -C "$REPO_DIR" rev-parse HEAD)"
  git -C "$REPO_DIR" checkout main -q
  git -C "$REPO_DIR" branch -D "eng-50-remote-parent" -q
  git -C "$REPO_DIR" update-ref "refs/remotes/origin/eng-50-remote-parent" "$parent_sha"

  local wt_path="$REPO_DIR/.worktrees/remote-parent-integration"

  run call_fn worktree_create_with_integration "$wt_path" "remote-parent-integration" "eng-50-remote-parent"

  [ "$status" -eq 0 ]
  [ -f "$wt_path/remote-only.txt" ]
}

# ---------------------------------------------------------------------------
# 6. worktree_create_with_integration — bad parent ref returns non-zero + stderr
# ---------------------------------------------------------------------------
@test "worktree_create_with_integration returns non-zero for a missing parent ref" {
  local wt_path="$REPO_DIR/.worktrees/bad-parent-integration"

  run call_fn worktree_create_with_integration "$wt_path" "bad-parent-integration" "nonexistent-branch"

  [ "$status" -ne 0 ]
  [[ "$output" =~ "parent ref not found" ]]
  # Pre-validation must fire before worktree creation — directory must not exist
  [ ! -d "$wt_path" ]
}

# ---------------------------------------------------------------------------
# 7. worktree_create_with_integration — two parents, content from both present
# ---------------------------------------------------------------------------
@test "worktree_create_with_integration merges content from two parents" {
  # Parent A: adds file-a.txt
  git -C "$REPO_DIR" checkout -b "eng-20-parent-a"
  echo "content from parent A" > "$REPO_DIR/file-a.txt"
  git -C "$REPO_DIR" add file-a.txt
  git -C "$REPO_DIR" commit -m "parent A adds file-a.txt"
  git -C "$REPO_DIR" checkout main

  # Parent B: adds file-b.txt
  git -C "$REPO_DIR" checkout -b "eng-21-parent-b"
  echo "content from parent B" > "$REPO_DIR/file-b.txt"
  git -C "$REPO_DIR" add file-b.txt
  git -C "$REPO_DIR" commit -m "parent B adds file-b.txt"
  git -C "$REPO_DIR" checkout main

  local wt_path="$REPO_DIR/.worktrees/two-parent-integration"

  run call_fn worktree_create_with_integration "$wt_path" "two-parent-integration" "eng-20-parent-a" "eng-21-parent-b"

  [ "$status" -eq 0 ]
  [ -f "$wt_path/file-a.txt" ]
  [ -f "$wt_path/file-b.txt" ]
}

# ---------------------------------------------------------------------------
# 8. worktree_create_with_integration — first parent conflict stops second merge
# ---------------------------------------------------------------------------
@test "worktree_create_with_integration multi-parent conflict fails fast (does not silently drop later parents)" {
  # Parent A: conflicts with main on conflict.txt
  git -C "$REPO_DIR" checkout -b "eng-30-conflict-a"
  echo "parent A version" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "parent A adds conflict.txt"
  git -C "$REPO_DIR" checkout main

  # main also adds conflict.txt — guarantees an add/add conflict with parent A
  echo "main version" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "main adds conflict.txt"

  # Parent B: adds a unique file — must NOT be merged (conflict aborted) but
  # the agent must NOT be silently dispatched against an integration missing it
  git -C "$REPO_DIR" checkout -b "eng-31-parent-b"
  echo "content from parent B" > "$REPO_DIR/file-b-unique.txt"
  git -C "$REPO_DIR" add file-b-unique.txt
  git -C "$REPO_DIR" commit -m "parent B adds file-b-unique.txt"
  git -C "$REPO_DIR" checkout main

  local wt_path="$REPO_DIR/.worktrees/two-parent-conflict"

  # Multi-parent conflict must fail fast — agent can't be expected to discover
  # parents that were never merged and never signaled (silent drop is the bug).
  run call_fn worktree_create_with_integration "$wt_path" "two-parent-conflict" "eng-30-conflict-a" "eng-31-parent-b"

  [ "$status" -ne 0 ]
  [[ "$output" =~ "merge conflict" ]] || [[ "$output" =~ "eng-30-conflict-a" ]]
  # Worktree dir was created by `git worktree add` — orchestrator's _cleanup_worktree handles teardown
}
