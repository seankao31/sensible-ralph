#!/usr/bin/env bats
# Tests for skills/close-issue/scripts/lib/preflight.sh
# Modeled after skills/sr-start/scripts/test/orchestrator.bats —
# function-level stubbing via STUB_DIR mirrored layout. See linear.bats
# in sr-start for the alternative PATH-stub pattern (used when testing
# helpers that wrap the linear CLI directly).
#
# This file uses the STUB_DIR pattern because preflight.sh consumes
# linear_get_issue_state — we want to control what that helper returns
# without going through the linear CLI. linear_get_issue_state itself is
# already covered (PATH-stubbed) in sr-start's linear.bats.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
PREFLIGHT_SH="$SCRIPT_DIR/lib/preflight.sh"

# ---------------------------------------------------------------------------
# Setup: STUB_DIR with mirrored lib/ layout containing the real preflight.sh
# and a fake linear.sh whose linear_get_issue_state is driven by env vars.
# ---------------------------------------------------------------------------
setup() {
  STUB_DIR="$(cd "$(mktemp -d)" && pwd -P)"
  export STUB_DIR

  mkdir -p "$STUB_DIR/lib"
  cp "$PREFLIGHT_SH" "$STUB_DIR/lib/preflight.sh"

  # Fake lib/linear.sh: linear_get_issue_state is driven by STUB_LINEAR_STATE
  # and STUB_LINEAR_RC. On non-zero RC, the fake also writes a diagnostic to
  # stderr so the "diagnostic surfaces" test can assert it isn't swallowed.
  cat > "$STUB_DIR/lib/linear.sh" <<'LINEARSH'
linear_get_issue_state() {
  local issue_id="$1"
  if [ "${STUB_LINEAR_RC:-0}" -ne 0 ]; then
    printf 'linear_get_issue_state: failed to view %s\n' "$issue_id" >&2
    return "$STUB_LINEAR_RC"
  fi
  printf '%s' "${STUB_LINEAR_STATE:-}"
}
LINEARSH

  # State-name env vars the plugin harness exports from userConfig.
  export CLAUDE_PLUGIN_OPTION_REVIEW_STATE="In Review"
  export CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE="In Progress"
  export CLAUDE_PLUGIN_OPTION_DONE_STATE="Done"
}

teardown() {
  rm -rf "$STUB_DIR"
}

# ---------------------------------------------------------------------------
# Helper: source the fakes + preflight in a subshell, call the function.
#
# call_fn uses `if fn; then rc=0; else rc=$?; fi` to distinguish `return`
# from `exit`: `set -e` is suppressed inside an `if` condition, so a compliant
# `return 1` goes to `else` and control reaches `echo CALL_FN_SENTINEL`; an
# illegal `exit 1` kills the subshell before the sentinel prints. Tests assert
# that CALL_FN_SENTINEL is present, proving the function used `return`.
# ---------------------------------------------------------------------------
call_fn() {
  local fn_name="$1"; shift
  bash -c "set -euo pipefail; source '$STUB_DIR/lib/linear.sh'; source '$STUB_DIR/lib/preflight.sh'; if $fn_name $*; then rc=0; else rc=\$?; fi; echo CALL_FN_SENTINEL; exit \$rc"
}

# ---------------------------------------------------------------------------
# 1. Happy path — state matches review state → returns 0, sentinel only
# ---------------------------------------------------------------------------
@test "close_issue_check_review_state returns 0 when state matches review state" {
  STUB_LINEAR_STATE="In Review"
  export STUB_LINEAR_STATE

  run call_fn close_issue_check_review_state ENG-100

  [ "$status" -eq 0 ]
  [ "$output" = "CALL_FN_SENTINEL" ]  # sentinel only — no error messages, proves return was used
}

# ---------------------------------------------------------------------------
# 2. In Progress — returns 1, stderr nudges toward /prepare-for-review
# ---------------------------------------------------------------------------
@test "close_issue_check_review_state returns 1 with /prepare-for-review hint when state is in progress" {
  STUB_LINEAR_STATE="In Progress"
  export STUB_LINEAR_STATE

  run call_fn close_issue_check_review_state ENG-101

  [ "$status" -ne 0 ]
  [[ "$output" == *"CALL_FN_SENTINEL"* ]]  # sentinel present — proves return 1, not exit 1
  if [[ "$output" != *"/prepare-for-review"* ]]; then
    echo "expected /prepare-for-review hint in output, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 3. Done — returns 1, stderr nudges toward leftover-worktree investigation
# ---------------------------------------------------------------------------
@test "close_issue_check_review_state returns 1 with leftover-worktree hint when state is done" {
  STUB_LINEAR_STATE="Done"
  export STUB_LINEAR_STATE

  run call_fn close_issue_check_review_state ENG-102

  [ "$status" -ne 0 ]
  [[ "$output" == *"CALL_FN_SENTINEL"* ]]  # sentinel present — proves return 1, not exit 1
  if [[ "$output" != *"Investigate"* ]] && [[ "$output" != *"leftover"* ]]; then
    echo "expected 'Investigate' or 'leftover' hint in output, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 4. Any other state — returns 1, stderr says dispatch lifecycle is off
# ---------------------------------------------------------------------------
@test "close_issue_check_review_state returns 1 with dispatch-lifecycle hint when state is unknown" {
  STUB_LINEAR_STATE="Backlog"
  export STUB_LINEAR_STATE

  run call_fn close_issue_check_review_state ENG-103

  [ "$status" -ne 0 ]
  [[ "$output" == *"CALL_FN_SENTINEL"* ]]  # sentinel present — proves return 1, not exit 1
  if [[ "$output" != *"dispatch lifecycle"* ]]; then
    echo "expected 'dispatch lifecycle' hint in output, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 5. Helper failure — returns 1; the helper's diagnostic must surface, not
#    be swallowed (the SKILL.md inline call had `2>/dev/null` swallowing
#    Linear API errors; this function is the canonical replacement).
# ---------------------------------------------------------------------------
@test "close_issue_check_review_state surfaces linear_get_issue_state's stderr on helper failure" {
  STUB_LINEAR_RC=1
  export STUB_LINEAR_RC

  run call_fn close_issue_check_review_state ENG-104

  [ "$status" -ne 0 ]
  [[ "$output" == *"CALL_FN_SENTINEL"* ]]  # sentinel present — proves return 1, not exit 1
  if [[ "$output" != *"linear_get_issue_state: failed to view"* ]]; then
    echo "expected helper diagnostic in output, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 6. Harness self-test — proves call_fn detects illegal `exit` calls.
#    A sourced function that calls `exit 1` instead of `return 1` kills the
#    subshell before CALL_FN_SENTINEL prints. If this test ever stops
#    catching that (e.g., sentinel always prints), the harness is broken.
# ---------------------------------------------------------------------------
@test "call_fn sentinel is absent when a sourced function calls exit (harness self-test)" {
  printf 'exit_fn() { exit 1; }\n' > "$STUB_DIR/lib/preflight.sh"

  run call_fn exit_fn

  [ "$status" -ne 0 ]
  [[ "$output" != *"CALL_FN_SENTINEL"* ]]
}
