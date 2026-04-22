#!/usr/bin/env bats
# Tests for scripts/lib/branch_ancestry.sh
# Each test builds a controlled temp git repo so ancestry can be reasoned
# about directly. ENG-208's stale-parent check is the motivating consumer.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
BRANCH_ANCESTRY_SH="$SCRIPT_DIR/lib/branch_ancestry.sh"

# ---------------------------------------------------------------------------
# Setup: fresh temp repo per test with an initial commit on `main`.
# cd into the repo so the helpers (which use plain `git` commands) operate
# on the per-test fixture rather than the caller's repo.
# ---------------------------------------------------------------------------
setup() {
  TEST_REPO="$(mktemp -d)"
  git -C "$TEST_REPO" init --quiet --initial-branch=main
  git -C "$TEST_REPO" config user.email "test@example.com"
  git -C "$TEST_REPO" config user.name "Test"
  printf 'seed\n' > "$TEST_REPO/file"
  git -C "$TEST_REPO" add file
  git -C "$TEST_REPO" commit --quiet -m 'seed'
  cd "$TEST_REPO"
}

teardown() {
  cd /
  rm -rf "$TEST_REPO"
}

call_fn() {
  local fn_name="$1"; shift
  # Sourcing per call is cheaper than persisting shell state and keeps each
  # test's subshell hermetic.
  bash -c "source '$BRANCH_ANCESTRY_SH' && $fn_name \"\$@\"" _ "$@"
}

# ---------------------------------------------------------------------------
# Helper: make a commit on the current branch and echo its SHA.
# ---------------------------------------------------------------------------
commit_on() {
  local msg="$1"
  printf '%s\n' "$msg" >> file
  git add file
  git commit --quiet -m "$msg"
  git rev-parse HEAD
}

# ===========================================================================
# is_branch_fresh_vs_sha
# ===========================================================================

# Topology: main → A1, child branches off main at A1.
# A1 is a direct ancestor of child, so is_branch_fresh_vs_sha must return 0.
@test "is_branch_fresh_vs_sha: parent_sha is direct ancestor of branch → exit 0 (fresh)" {
  git checkout -q main
  local a_sha
  a_sha=$(commit_on "a1")
  git checkout -q -b child
  commit_on "c1" > /dev/null

  run call_fn is_branch_fresh_vs_sha "$a_sha" "refs/heads/child"

  [ "$status" -eq 0 ]
}

# Topology: main → A1, child branches at A1, main amends to A2 (A1 is replaced
# by A2 via reset+new-commit; A2 is NOT an ancestor of child).
@test "is_branch_fresh_vs_sha: parent_sha diverged from branch → exit 1 (stale)" {
  git checkout -q main
  local a1_sha
  a1_sha=$(commit_on "a1")
  git checkout -q -b child
  commit_on "c1" > /dev/null

  # Amend main: reset to pre-a1, then add a2 — a2 is a sibling of a1, not an ancestor of child.
  git checkout -q main
  git reset --hard --quiet HEAD~1
  local a2_sha
  a2_sha=$(commit_on "a2")

  run call_fn is_branch_fresh_vs_sha "$a2_sha" "refs/heads/child"

  [ "$status" -eq 1 ]
}

@test "is_branch_fresh_vs_sha: bad parent_sha → exit 2 with diagnostic on stderr" {
  run call_fn is_branch_fresh_vs_sha "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "refs/heads/main"

  [ "$status" -eq 2 ]
  [[ "$output" == *"is_branch_fresh_vs_sha"* ]]
}

@test "is_branch_fresh_vs_sha: missing branch_ref → exit 2 with diagnostic on stderr" {
  local main_sha
  main_sha=$(git rev-parse HEAD)

  run call_fn is_branch_fresh_vs_sha "$main_sha" "refs/heads/does-not-exist"

  [ "$status" -eq 2 ]
  [[ "$output" == *"is_branch_fresh_vs_sha"* ]]
}

# ===========================================================================
# list_commits_ahead
# ===========================================================================

# Parent has 3 commits beyond the fork point; branch has just the fork commit.
@test "list_commits_ahead: three commits on parent beyond fork → 3 lines, exit 0" {
  git checkout -q main
  commit_on "fork" > /dev/null
  git checkout -q -b child
  # Parent advances three commits beyond the fork.
  git checkout -q main
  commit_on "p1" > /dev/null
  commit_on "p2" > /dev/null
  local p3_sha
  p3_sha=$(commit_on "p3")

  run call_fn list_commits_ahead "$p3_sha" "refs/heads/child"

  [ "$status" -eq 0 ]
  local line_count
  line_count=$(printf '%s\n' "$output" | grep -c .)
  [ "$line_count" -eq 3 ]
}

@test "list_commits_ahead: parent_sha equals branch tip → empty stdout, exit 0" {
  git checkout -q -b child
  local tip_sha
  tip_sha=$(git rev-parse HEAD)

  run call_fn list_commits_ahead "$tip_sha" "refs/heads/child"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "list_commits_ahead: bad parent_sha → non-zero exit" {
  run call_fn list_commits_ahead "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "refs/heads/main"

  [ "$status" -ne 0 ]
}

@test "list_commits_ahead: missing branch_ref → non-zero exit" {
  local main_sha
  main_sha=$(git rev-parse HEAD)

  run call_fn list_commits_ahead "$main_sha" "refs/heads/does-not-exist"

  [ "$status" -ne 0 ]
}

# ===========================================================================
# resolve_branch_for_issue
# ===========================================================================

@test "resolve_branch_for_issue: unique local branch matching issue slug → branch name, exit 0" {
  git checkout -q -b eng-123-some-feature

  run call_fn resolve_branch_for_issue "ENG-123"

  [ "$status" -eq 0 ]
  [ "$output" = "eng-123-some-feature" ]
}

@test "resolve_branch_for_issue: multiple matching branches → exit 2, both on stderr" {
  git checkout -q -b eng-123-first
  git checkout -q main
  git checkout -q -b eng-123-second

  run call_fn resolve_branch_for_issue "ENG-123"

  [ "$status" -eq 2 ]
  [[ "$output" == *"eng-123-first"* ]]
  [[ "$output" == *"eng-123-second"* ]]
}

@test "resolve_branch_for_issue: no matching branch → exit 1 with diagnostic on stderr" {
  run call_fn resolve_branch_for_issue "ENG-999"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ENG-999"* ]] || [[ "$output" == *"eng-999"* ]]
}
