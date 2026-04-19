#!/usr/bin/env bats
# Tests for scripts/dag_base.sh
# Stubs linear_get_issue_blockers to avoid real API calls.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DAG_BASE="$SCRIPT_DIR/dag_base.sh"
LINEAR_SH="$SCRIPT_DIR/lib/linear.sh"

# ---------------------------------------------------------------------------
# Setup: set required env vars and stub linear_get_issue_blockers
# ---------------------------------------------------------------------------
setup() {
  export RALPH_REVIEW_STATE="In Review"
  export RALPH_APPROVED_STATE="Approved"
  export RALPH_PROJECT="Agent Config"
  export RALPH_FAILED_LABEL="ralph-failed"
}

# ---------------------------------------------------------------------------
# Helper: run dag_base.sh with a stubbed linear_get_issue_blockers.
# STUB_BLOCKERS_JSON is the JSON the stub function will return.
# ---------------------------------------------------------------------------
run_dag_base() {
  local issue_id="$1"
  local blockers_json="$2"
  # dag_base.sh sources lib/linear.sh; we prepend a bash file that defines
  # linear_get_issue_blockers before sourcing, so the real function is
  # never defined (bash uses first definition when the file is sourced with
  # no re-source protection).
  # Strategy: write a wrapper script that defines the stub, sources dag_base
  # by injecting via PATH shim on lib/linear.sh is complex — instead,
  # create a temp linear.sh that only defines the stub function, then
  # set RALPH_LINEAR_SH_OVERRIDE so dag_base.sh picks it up.
  #
  # Simpler approach: create a temp dir with a fake lib/linear.sh that only
  # defines the stub, and override the SCRIPT_DIR seen by dag_base.sh is
  # not possible without modifying dag_base.sh.
  #
  # Correct approach: write a small wrapper that sources the stub inline
  # before sourcing dag_base.sh would source linear.sh. Since dag_base.sh
  # sources $(dirname "$0")/lib/linear.sh, we create a temp copy of
  # dag_base.sh alongside a temp lib/linear.sh stub.

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/lib"

  # Write stub lib/linear.sh — only defines the function we need
  cat > "$tmp_dir/lib/linear.sh" <<STUB
linear_get_issue_blockers() {
  printf '%s' '$blockers_json'
}
STUB

  # Symlink dag_base.sh into temp dir so \$(dirname "\$0")/lib/linear.sh resolves correctly
  cp "$DAG_BASE" "$tmp_dir/dag_base.sh"

  run bash "$tmp_dir/dag_base.sh" "$issue_id"
  rm -rf "$tmp_dir"
}

# ---------------------------------------------------------------------------
# 1. No blockers (empty JSON array) → output "main"
# ---------------------------------------------------------------------------
@test "no blockers outputs main" {
  run_dag_base "ENG-100" "[]"

  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# ---------------------------------------------------------------------------
# 2. All blockers Done (state != RALPH_REVIEW_STATE) → output "main"
# ---------------------------------------------------------------------------
@test "all blockers done outputs main" {
  local blockers
  blockers='[{"id":"ENG-10","state":"Done","branch":"eng-10-foo"},{"id":"ENG-11","state":"Cancelled","branch":"eng-11-bar"}]'
  run_dag_base "ENG-100" "$blockers"

  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# ---------------------------------------------------------------------------
# 3. One blocker In Review → output its branch name
# ---------------------------------------------------------------------------
@test "one blocker in review outputs its branch name" {
  local blockers
  blockers='[{"id":"ENG-20","state":"In Review","branch":"eng-20-feature"}]'
  run_dag_base "ENG-100" "$blockers"

  [ "$status" -eq 0 ]
  [ "$output" = "eng-20-feature" ]
}

# ---------------------------------------------------------------------------
# 4. Multiple blockers In Review → output INTEGRATION branch1 branch2 ...
# ---------------------------------------------------------------------------
@test "multiple blockers in review outputs INTEGRATION with branches" {
  local blockers
  blockers='[{"id":"ENG-30","state":"In Review","branch":"eng-30-a"},{"id":"ENG-31","state":"In Review","branch":"eng-31-b"}]'
  run_dag_base "ENG-100" "$blockers"

  [ "$status" -eq 0 ]
  [ "$output" = "INTEGRATION eng-30-a eng-31-b" ]
}

# ---------------------------------------------------------------------------
# 5. Mixed: one Done + one In Review → only In Review matters → single branch
# ---------------------------------------------------------------------------
@test "mixed done and in review outputs single branch name" {
  local blockers
  blockers='[{"id":"ENG-40","state":"Done","branch":"eng-40-done"},{"id":"ENG-41","state":"In Review","branch":"eng-41-review"}]'
  run_dag_base "ENG-100" "$blockers"

  [ "$status" -eq 0 ]
  [ "$output" = "eng-41-review" ]
}
