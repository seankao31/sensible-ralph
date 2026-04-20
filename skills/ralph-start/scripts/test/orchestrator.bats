#!/usr/bin/env bats
# Tests for scripts/orchestrator.sh
# Stubs lib/linear.sh (fake functions), dag_base.sh, and the `claude` CLI
# via a mirrored temp directory layout so orchestrator sources the fakes.
# Uses a real throwaway git repo so worktree operations run for real.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ORCH_SH="$SCRIPT_DIR/orchestrator.sh"
WORKTREE_SH="$SCRIPT_DIR/lib/worktree.sh"

# ---------------------------------------------------------------------------
# Setup: real git repo + STUB_DIR with mirrored scripts/ layout
# ---------------------------------------------------------------------------
setup() {
  STUB_DIR="$(cd "$(mktemp -d)" && pwd -P)"
  export STUB_DIR

  REPO_DIR="$(cd "$(mktemp -d)" && pwd -P)"
  export REPO_DIR
  git -C "$REPO_DIR" init -b main -q
  git -C "$REPO_DIR" config user.email "t@t.com"
  git -C "$REPO_DIR" config user.name "t"
  git -C "$REPO_DIR" commit --allow-empty -m "init" -q

  # Env vars config.sh would export
  export RALPH_PROJECT="Test Project"
  export RALPH_APPROVED_STATE="Approved"
  export RALPH_REVIEW_STATE="In Review"
  export RALPH_FAILED_LABEL="ralph-failed"
  export RALPH_WORKTREE_BASE=".worktrees"
  export RALPH_MODEL="opus"
  export RALPH_STDOUT_LOG="ralph-output.log"
  export RALPH_PROMPT_TEMPLATE='Issue: $ISSUE_ID Title: $ISSUE_TITLE Branch: $BRANCH_NAME Path: $WORKTREE_PATH'

  # Claude invocation capture + state-transition trace
  export STUB_CLAUDE_ARGS_FILE="$STUB_DIR/claude_args"
  : > "$STUB_CLAUDE_ARGS_FILE"
  export STUB_LINEAR_CALLS_FILE="$STUB_DIR/linear_calls"
  : > "$STUB_LINEAR_CALLS_FILE"

  # Stub layout: $STUB_DIR/scripts/{orchestrator.sh,dag_base.sh,lib/{linear.sh,worktree.sh}}
  mkdir -p "$STUB_DIR/scripts/lib"
  cp "$ORCH_SH" "$STUB_DIR/scripts/orchestrator.sh"
  # Real worktree.sh — we want real git worktree operations
  cp "$WORKTREE_SH" "$STUB_DIR/scripts/lib/worktree.sh"

  # Fake lib/linear.sh driven by env vars / fixture files.
  # Also records every call (function + args) to $STUB_LINEAR_CALLS_FILE.
  cat > "$STUB_DIR/scripts/lib/linear.sh" <<'LINEARSH'
# Fake lib/linear.sh for orchestrator tests.
#
# Data sources (all optional; default to benign values):
#   STUB_BLOCKERS_<issue_with_dashes_as_underscores>  JSON array like [{"id":"ENG-X","state":"Done","branch":"eng-x"}]
#   STUB_BRANCH_<issue>                                Branch name string (default: lowercase issue id)
#   STUB_TITLE_<issue>                                 Title string
#   $STUB_DIR/linear_state_<issue>                     Current state name (mutated by claude stub)

_issue_var() {
  # Convert ENG-10 -> ENG_10 for env var lookup
  printf '%s' "$1" | tr '-' '_'
}

linear_get_issue_blockers() {
  local issue_id="$1"
  printf 'get_blockers %s\n' "$issue_id" >> "$STUB_LINEAR_CALLS_FILE"
  local key; key="$(_issue_var "$issue_id")"
  # If STUB_BLOCKERS_FAIL_<id> is set, simulate a transient relation-list failure.
  local fail_var="STUB_BLOCKERS_FAIL_${key}"
  if [[ -n "${!fail_var:-}" ]]; then
    printf 'stub: linear_get_issue_blockers failed for %s\n' "$issue_id" >&2
    return 1
  fi
  local var="STUB_BLOCKERS_${key}"
  printf '%s' "${!var:-[]}"
}

linear_get_issue_branch() {
  local issue_id="$1"
  printf 'get_branch %s\n' "$issue_id" >> "$STUB_LINEAR_CALLS_FILE"
  local key; key="$(_issue_var "$issue_id")"
  local var="STUB_BRANCH_${key}"
  # Default: lowercase the issue id (eng-10)
  local default; default="$(printf '%s' "$issue_id" | tr '[:upper:]' '[:lower:]')"
  printf '%s' "${!var:-$default}"
}

linear_set_state() {
  local issue_id="$1"
  local state="$2"
  printf 'set_state %s %s\n' "$issue_id" "$state" >> "$STUB_LINEAR_CALLS_FILE"
  local key; key="$(_issue_var "$issue_id")"
  local fail_var="STUB_SET_STATE_FAIL_${key}"
  if [[ -n "${!fail_var:-}" ]]; then
    printf 'stub: linear_set_state failed for %s\n' "$issue_id" >&2
    return 1
  fi
  printf '%s' "$state" > "$STUB_DIR/linear_state_$issue_id"
}

linear_add_label() {
  local issue_id="$1"
  local label="$2"
  printf 'add_label %s %s\n' "$issue_id" "$label" >> "$STUB_LINEAR_CALLS_FILE"
  local key; key="$(_issue_var "$issue_id")"
  local fail_var="STUB_ADD_LABEL_FAIL_${key}"
  if [[ -n "${!fail_var:-}" ]]; then
    printf 'stub: linear_add_label failed for %s\n' "$issue_id" >&2
    return 1
  fi
}

linear_comment() {
  local issue_id="$1"
  local body="$2"
  printf 'comment %s %s\n' "$issue_id" "$body" >> "$STUB_LINEAR_CALLS_FILE"
}

# Title lookup helper used by orchestrator. Exposed as a separate function
# so the orchestrator doesn't need to shell out to the real `linear` CLI.
linear_get_issue_title() {
  local issue_id="$1"
  printf 'get_title %s\n' "$issue_id" >> "$STUB_LINEAR_CALLS_FILE"
  local key; key="$(_issue_var "$issue_id")"
  local var="STUB_TITLE_${key}"
  printf '%s' "${!var:-Title for $issue_id}"
}

# Post-dispatch state query helper. Reads from $STUB_DIR/linear_state_<id>.
linear_get_issue_state() {
  local issue_id="$1"
  printf 'get_state %s\n' "$issue_id" >> "$STUB_LINEAR_CALLS_FILE"
  local key; key="$(_issue_var "$issue_id")"
  local fail_var="STUB_GET_STATE_FAIL_${key}"
  if [[ -n "${!fail_var:-}" ]]; then
    printf 'stub: linear_get_issue_state failed for %s\n' "$issue_id" >&2
    return 1
  fi
  local f="$STUB_DIR/linear_state_$issue_id"
  if [[ -f "$f" ]]; then
    cat "$f"
  else
    # Default: Approved (pre-dispatch)
    printf '%s' "${RALPH_APPROVED_STATE:-Approved}"
  fi
}
LINEARSH

  # Stub dag_base.sh — reads STUB_DAG_BASE_<issue> env var; default "main"
  cat > "$STUB_DIR/scripts/dag_base.sh" <<'DAGSH'
#!/usr/bin/env bash
set -euo pipefail
issue_id="$1"
key="$(printf '%s' "$issue_id" | tr '-' '_')"
var="STUB_DAG_BASE_${key}"
printf '%s\n' "${!var:-main}"
DAGSH
  chmod +x "$STUB_DIR/scripts/dag_base.sh"

  # Stub claude via PATH. Records argv, optionally transitions Linear state.
  cat > "$STUB_DIR/claude" <<'CLAUDESH'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$STUB_CLAUDE_ARGS_FILE"
printf '\n' >> "$STUB_CLAUDE_ARGS_FILE"
if [[ -n "${STUB_CLAUDE_TRANSITION_STATE:-}" && -n "${STUB_CLAUDE_ISSUE_ID:-}" ]]; then
  printf '%s' "$STUB_CLAUDE_TRANSITION_STATE" > "$STUB_DIR/linear_state_$STUB_CLAUDE_ISSUE_ID"
fi
exit "${STUB_CLAUDE_EXIT:-0}"
CLAUDESH
  chmod +x "$STUB_DIR/claude"
  export PATH="$STUB_DIR:$PATH"
}

teardown() {
  rm -rf "$STUB_DIR" "$REPO_DIR"
}

# ---------------------------------------------------------------------------
# Helper: write a queue file and run orchestrator from the repo dir
# ---------------------------------------------------------------------------
write_queue() {
  local queue_file="$STUB_DIR/queue"
  : > "$queue_file"
  for id in "$@"; do
    printf '%s\n' "$id" >> "$queue_file"
  done
  printf '%s' "$queue_file"
}

run_orch() {
  local queue_file="$1"
  run bash -c "cd '$REPO_DIR' && '$STUB_DIR/scripts/orchestrator.sh' '$queue_file'"
}

# Read progress.json records (jq-friendly). progress.json lives in $REPO_DIR.
progress_json() {
  cat "$REPO_DIR/progress.json"
}

# ---------------------------------------------------------------------------
# 1. Clean single-issue success: exit 0 + state transitions to In Review
# ---------------------------------------------------------------------------
@test "single issue success: outcome=in_review, .ralph-base-sha present, Linear set to In Progress" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"
  export STUB_CLAUDE_ISSUE_ID="ENG-10"

  local q; q="$(write_queue ENG-10)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # claude was invoked once
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 1 ]

  # Linear state was set to In Progress at dispatch
  grep -qF "set_state ENG-10 In Progress" "$STUB_LINEAR_CALLS_FILE"

  # Worktree exists; .ralph-base-sha is present and is a 40-char hex SHA
  local wt_path="$REPO_DIR/.worktrees/eng-10"
  [ -d "$wt_path" ]
  [ -f "$wt_path/.ralph-base-sha" ]
  local sha; sha="$(cat "$wt_path/.ralph-base-sha")"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]]

  # progress.json has exactly one in_review record
  [ -f "$REPO_DIR/progress.json" ]
  local count; count="$(jq 'length' < "$REPO_DIR/progress.json")"
  [ "$count" -eq 1 ]
  local outcome; outcome="$(jq -r '.[0].outcome' < "$REPO_DIR/progress.json")"
  [ "$outcome" = "in_review" ]
  local issue; issue="$(jq -r '.[0].issue' < "$REPO_DIR/progress.json")"
  [ "$issue" = "ENG-10" ]
}

# ---------------------------------------------------------------------------
# 2. Clean queue (3 independent): all succeed
# ---------------------------------------------------------------------------
@test "clean queue of 3 independent issues: all transition to in_review" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"
  # STUB_CLAUDE_ISSUE_ID is set per-invocation; we use a different approach:
  # since the stub needs per-issue transition, we write all three state files
  # via a smarter stub. Replace the simple stub with one that reads the issue
  # id from the --name arg.
  cat > "$STUB_DIR/claude" <<'CLAUDESH'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$STUB_CLAUDE_ARGS_FILE"
printf '\n' >> "$STUB_CLAUDE_ARGS_FILE"
# Extract issue id from --name "ENG-X: Title"
issue_id=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--name" ]]; then
    shift
    issue_id="${1%%:*}"
    break
  fi
  shift
done
if [[ -n "${STUB_CLAUDE_TRANSITION_STATE:-}" && -n "$issue_id" ]]; then
  printf '%s' "$STUB_CLAUDE_TRANSITION_STATE" > "$STUB_DIR/linear_state_$issue_id"
fi
exit "${STUB_CLAUDE_EXIT:-0}"
CLAUDESH
  chmod +x "$STUB_DIR/claude"

  local q; q="$(write_queue ENG-10 ENG-11 ENG-12)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # 3 claude invocations
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 3 ]

  # 3 in_review records
  local count; count="$(jq 'length' < "$REPO_DIR/progress.json")"
  [ "$count" -eq 3 ]
  local in_review_count; in_review_count="$(jq '[.[] | select(.outcome == "in_review")] | length' < "$REPO_DIR/progress.json")"
  [ "$in_review_count" -eq 3 ]
}

# ---------------------------------------------------------------------------
# 3. Hard failure: exit non-zero -> ralph-failed label, outcome=failed
# ---------------------------------------------------------------------------
@test "hard failure: exit non-zero adds ralph-failed label, outcome=failed with exit_code" {
  export STUB_CLAUDE_EXIT=7
  # No state transition — session crashed

  local q; q="$(write_queue ENG-20)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # ralph-failed label was added
  grep -qF "add_label ENG-20 ralph-failed" "$STUB_LINEAR_CALLS_FILE"

  # progress.json outcome=failed with exit_code=7
  local outcome; outcome="$(jq -r '.[0].outcome' < "$REPO_DIR/progress.json")"
  [ "$outcome" = "failed" ]
  local exit_code; exit_code="$(jq -r '.[0].exit_code' < "$REPO_DIR/progress.json")"
  [ "$exit_code" = "7" ]
}

# ---------------------------------------------------------------------------
# 4. Soft failure: exit 0 but state stayed at In Progress (Q2 case)
# ---------------------------------------------------------------------------
@test "soft failure: exit 0 without state transition adds ralph-failed, outcome=exit_clean_no_review" {
  export STUB_CLAUDE_EXIT=0
  # No STUB_CLAUDE_TRANSITION_STATE — stub won't move state beyond "In Progress"

  local q; q="$(write_queue ENG-30)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  grep -qF "add_label ENG-30 ralph-failed" "$STUB_LINEAR_CALLS_FILE"

  local outcome; outcome="$(jq -r '.[0].outcome' < "$REPO_DIR/progress.json")"
  [ "$outcome" = "exit_clean_no_review" ]
}

# ---------------------------------------------------------------------------
# 5. Failure taints downstream: ENG-A blocks ENG-B; ENG-A fails -> ENG-B skipped
# ---------------------------------------------------------------------------
@test "hard failure taints direct downstream: dependent issue is skipped" {
  export STUB_CLAUDE_EXIT=3
  # ENG-41 is blocked by ENG-40
  export STUB_BLOCKERS_ENG_41='[{"id":"ENG-40","state":"Approved","branch":"eng-40"}]'
  export STUB_BLOCKERS_ENG_40='[]'

  local q; q="$(write_queue ENG-40 ENG-41)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # Only ENG-40 was dispatched — claude called exactly once
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 1 ]

  # Verify that invocation was for ENG-40 (via --name flag)
  grep -qF "ENG-40" "$STUB_CLAUDE_ARGS_FILE"
  ! grep -qF "ENG-41:" "$STUB_CLAUDE_ARGS_FILE"

  # progress.json: ENG-40 failed, ENG-41 skipped
  local records; records="$(jq 'length' < "$REPO_DIR/progress.json")"
  [ "$records" -eq 2 ]
  local eng40_outcome; eng40_outcome="$(jq -r '.[] | select(.issue == "ENG-40") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng40_outcome" = "failed" ]
  local eng41_outcome; eng41_outcome="$(jq -r '.[] | select(.issue == "ENG-41") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng41_outcome" = "skipped" ]
}

# ---------------------------------------------------------------------------
# 6. Soft failure also taints downstream
# ---------------------------------------------------------------------------
@test "soft failure taints downstream too" {
  export STUB_CLAUDE_EXIT=0
  # No transition state -> soft failure
  export STUB_BLOCKERS_ENG_51='[{"id":"ENG-50","state":"Approved","branch":"eng-50"}]'
  export STUB_BLOCKERS_ENG_50='[]'

  local q; q="$(write_queue ENG-50 ENG-51)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 1 ]

  local eng51_outcome; eng51_outcome="$(jq -r '.[] | select(.issue == "ENG-51") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng51_outcome" = "skipped" ]
}

# ---------------------------------------------------------------------------
# 7. Failure does NOT taint independents
# ---------------------------------------------------------------------------
@test "failure does not taint independent issues: unrelated issue still dispatched" {
  export STUB_BLOCKERS_ENG_60='[]'
  export STUB_BLOCKERS_ENG_61='[]'

  # Use a smarter claude stub: ENG-60 fails hard, ENG-61 succeeds cleanly.
  cat > "$STUB_DIR/claude" <<'CLAUDESH'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$STUB_CLAUDE_ARGS_FILE"
printf '\n' >> "$STUB_CLAUDE_ARGS_FILE"
issue_id=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--name" ]]; then
    shift
    issue_id="${1%%:*}"
    break
  fi
  shift
done
case "$issue_id" in
  ENG-60) exit 5 ;;
  ENG-61) printf 'In Review' > "$STUB_DIR/linear_state_$issue_id"; exit 0 ;;
  *) exit 1 ;;
esac
CLAUDESH
  chmod +x "$STUB_DIR/claude"

  local q; q="$(write_queue ENG-60 ENG-61)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # Both dispatched
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 2 ]

  local eng60_outcome; eng60_outcome="$(jq -r '.[] | select(.issue == "ENG-60") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng60_outcome" = "failed" ]
  local eng61_outcome; eng61_outcome="$(jq -r '.[] | select(.issue == "ENG-61") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng61_outcome" = "in_review" ]
}

# ---------------------------------------------------------------------------
# 8. Transitive taint: A -> B -> C; A fails -> both B AND C skipped
# ---------------------------------------------------------------------------
@test "transitive taint: grandchild of failed issue is also skipped" {
  export STUB_CLAUDE_EXIT=2
  export STUB_BLOCKERS_ENG_70='[]'
  export STUB_BLOCKERS_ENG_71='[{"id":"ENG-70","state":"Approved","branch":"eng-70"}]'
  export STUB_BLOCKERS_ENG_72='[{"id":"ENG-71","state":"Approved","branch":"eng-71"}]'

  local q; q="$(write_queue ENG-70 ENG-71 ENG-72)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # Only ENG-70 dispatched
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 1 ]

  local eng71_outcome; eng71_outcome="$(jq -r '.[] | select(.issue == "ENG-71") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng71_outcome" = "skipped" ]
  local eng72_outcome; eng72_outcome="$(jq -r '.[] | select(.issue == "ENG-72") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng72_outcome" = "skipped" ]
}

# ---------------------------------------------------------------------------
# 9. Integration base: INTEGRATION b1 b2 -> worktree_create_with_integration
# ---------------------------------------------------------------------------
@test "integration base dispatch: worktree created from two parent branches" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # Make two real parent branches in the fixture repo so integration merge works.
  git -C "$REPO_DIR" checkout -b eng-80-parent-a -q
  echo "a" > "$REPO_DIR/a.txt"
  git -C "$REPO_DIR" add a.txt
  git -C "$REPO_DIR" commit -m "parent a" -q
  git -C "$REPO_DIR" checkout main -q

  git -C "$REPO_DIR" checkout -b eng-81-parent-b -q
  echo "b" > "$REPO_DIR/b.txt"
  git -C "$REPO_DIR" add b.txt
  git -C "$REPO_DIR" commit -m "parent b" -q
  git -C "$REPO_DIR" checkout main -q

  # Stub dag_base for ENG-82 to output INTEGRATION with both parents
  export STUB_DAG_BASE_ENG_82="INTEGRATION eng-80-parent-a eng-81-parent-b"
  export STUB_CLAUDE_ISSUE_ID="ENG-82"

  local q; q="$(write_queue ENG-82)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # The integration worktree must contain files from BOTH parents
  local wt_path="$REPO_DIR/.worktrees/eng-82"
  [ -d "$wt_path" ]
  [ -f "$wt_path/a.txt" ]
  [ -f "$wt_path/b.txt" ]
  [ -f "$wt_path/.ralph-base-sha" ]
}

# ---------------------------------------------------------------------------
# 10. P1: integration base records main's SHA (NOT post-merge HEAD) in .ralph-base-sha
# ---------------------------------------------------------------------------
@test "integration base records main's SHA in .ralph-base-sha, not post-merge HEAD" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # Build a parent branch with real commits so merge produces a non-empty diff
  # and the post-merge HEAD is different from main.
  git -C "$REPO_DIR" checkout -b eng-90-parent-a -q
  echo "a" > "$REPO_DIR/a.txt"
  git -C "$REPO_DIR" add a.txt
  git -C "$REPO_DIR" commit -m "parent a" -q
  git -C "$REPO_DIR" checkout main -q

  # Capture main's SHA now — this is what .ralph-base-sha should contain.
  local main_sha; main_sha="$(git -C "$REPO_DIR" rev-parse main)"

  export STUB_DAG_BASE_ENG_91="INTEGRATION eng-90-parent-a"
  export STUB_CLAUDE_ISSUE_ID="ENG-91"

  local q; q="$(write_queue ENG-91)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  local wt_path="$REPO_DIR/.worktrees/eng-91"
  [ -f "$wt_path/.ralph-base-sha" ]

  local recorded_sha; recorded_sha="$(cat "$wt_path/.ralph-base-sha")"
  local post_merge_sha; post_merge_sha="$(git -C "$wt_path" rev-parse HEAD)"

  # The recorded SHA must equal main's SHA (branch creation point)
  [ "$recorded_sha" = "$main_sha" ]

  # Sanity: post-merge HEAD must differ from main (proves the merge happened)
  [ "$post_merge_sha" != "$main_sha" ]

  # Therefore recorded_sha must differ from post-merge HEAD
  [ "$recorded_sha" != "$post_merge_sha" ]
}

# ---------------------------------------------------------------------------
# 11. I1: per-issue fault isolation — worktree creation failure does NOT abort loop
# ---------------------------------------------------------------------------
@test "setup failure (branch already exists): outcome=setup_failed, descendants tainted, loop continues" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # Pre-create the branch for ENG-100 so `git worktree add -b eng-100` fails.
  git -C "$REPO_DIR" branch eng-100

  # ENG-101 depends on ENG-100; ENG-102 is independent.
  export STUB_BLOCKERS_ENG_100='[]'
  export STUB_BLOCKERS_ENG_101='[{"id":"ENG-100","state":"Approved","branch":"eng-100"}]'
  export STUB_BLOCKERS_ENG_102='[]'

  # Use the smart per-issue stub so ENG-102 transitions correctly.
  cat > "$STUB_DIR/claude" <<'CLAUDESH'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$STUB_CLAUDE_ARGS_FILE"
printf '\n' >> "$STUB_CLAUDE_ARGS_FILE"
issue_id=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--name" ]]; then
    shift
    issue_id="${1%%:*}"
    break
  fi
  shift
done
if [[ -n "${STUB_CLAUDE_TRANSITION_STATE:-}" && -n "$issue_id" ]]; then
  printf '%s' "$STUB_CLAUDE_TRANSITION_STATE" > "$STUB_DIR/linear_state_$issue_id"
fi
exit 0
CLAUDESH
  chmod +x "$STUB_DIR/claude"

  local q; q="$(write_queue ENG-100 ENG-101 ENG-102)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # claude was invoked only for ENG-102 (ENG-100 failed setup, ENG-101 tainted)
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 1 ]
  grep -qF "ENG-102" "$STUB_CLAUDE_ARGS_FILE"
  ! grep -qF "ENG-100:" "$STUB_CLAUDE_ARGS_FILE"
  ! grep -qF "ENG-101:" "$STUB_CLAUDE_ARGS_FILE"

  # ralph-failed label was added to ENG-100
  grep -qF "add_label ENG-100 ralph-failed" "$STUB_LINEAR_CALLS_FILE"

  # progress.json has three records
  local records; records="$(jq 'length' < "$REPO_DIR/progress.json")"
  [ "$records" -eq 3 ]

  local eng100_outcome; eng100_outcome="$(jq -r '.[] | select(.issue == "ENG-100") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng100_outcome" = "setup_failed" ]

  # setup_failed record carries a step identifier
  local eng100_step; eng100_step="$(jq -r '.[] | select(.issue == "ENG-100") | .failed_step' < "$REPO_DIR/progress.json")"
  [ -n "$eng100_step" ]
  [ "$eng100_step" != "null" ]

  local eng101_outcome; eng101_outcome="$(jq -r '.[] | select(.issue == "ENG-101") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng101_outcome" = "skipped" ]

  local eng102_outcome; eng102_outcome="$(jq -r '.[] | select(.issue == "ENG-102") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng102_outcome" = "in_review" ]
}

# ---------------------------------------------------------------------------
# 12. I2: dag_base.sh returning empty output is treated as setup_failed
# ---------------------------------------------------------------------------
@test "dag_base.sh empty output: outcome=setup_failed, loop continues" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # Force dag_base to emit whitespace-only output for ENG-110. (Setting the
  # stub var to empty would hit bash's `:-` default in the stub; whitespace
  # exercises the validator's `${var// /}` emptiness check.)
  export STUB_DAG_BASE_ENG_110="   "

  export STUB_BLOCKERS_ENG_110='[]'
  export STUB_BLOCKERS_ENG_111='[]'

  cat > "$STUB_DIR/claude" <<'CLAUDESH'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$STUB_CLAUDE_ARGS_FILE"
printf '\n' >> "$STUB_CLAUDE_ARGS_FILE"
issue_id=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--name" ]]; then
    shift
    issue_id="${1%%:*}"
    break
  fi
  shift
done
if [[ -n "${STUB_CLAUDE_TRANSITION_STATE:-}" && -n "$issue_id" ]]; then
  printf '%s' "$STUB_CLAUDE_TRANSITION_STATE" > "$STUB_DIR/linear_state_$issue_id"
fi
exit 0
CLAUDESH
  chmod +x "$STUB_DIR/claude"

  local q; q="$(write_queue ENG-110 ENG-111)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # Only ENG-111 dispatched
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 1 ]
  grep -qF "ENG-111" "$STUB_CLAUDE_ARGS_FILE"

  local eng110_outcome; eng110_outcome="$(jq -r '.[] | select(.issue == "ENG-110") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng110_outcome" = "setup_failed" ]

  local eng111_outcome; eng111_outcome="$(jq -r '.[] | select(.issue == "ENG-111") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng111_outcome" = "in_review" ]
}

# ---------------------------------------------------------------------------
# 13. P1: phase-1 blocker-fetch failure for one issue must not abort the run
# ---------------------------------------------------------------------------
@test "phase-1 blocker fetch failure for one issue: orchestrator continues and dispatches all others" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # ENG-120 blockers-fetch fails transiently; ENG-121 and ENG-122 are fine
  # and independent.
  export STUB_BLOCKERS_FAIL_ENG_120=1
  export STUB_BLOCKERS_ENG_121='[]'
  export STUB_BLOCKERS_ENG_122='[]'

  # Per-issue transition stub
  cat > "$STUB_DIR/claude" <<'CLAUDESH'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$STUB_CLAUDE_ARGS_FILE"
printf '\n' >> "$STUB_CLAUDE_ARGS_FILE"
issue_id=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--name" ]]; then
    shift
    issue_id="${1%%:*}"
    break
  fi
  shift
done
if [[ -n "${STUB_CLAUDE_TRANSITION_STATE:-}" && -n "$issue_id" ]]; then
  printf '%s' "$STUB_CLAUDE_TRANSITION_STATE" > "$STUB_DIR/linear_state_$issue_id"
fi
exit 0
CLAUDESH
  chmod +x "$STUB_DIR/claude"

  local q; q="$(write_queue ENG-120 ENG-121 ENG-122)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # All three issues dispatched — the blocker-fetch failure for ENG-120 did
  # not abort the orchestrator or prevent its own or others' dispatch.
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 3 ]

  local records; records="$(jq 'length' < "$REPO_DIR/progress.json")"
  [ "$records" -eq 3 ]

  local eng120_outcome; eng120_outcome="$(jq -r '.[] | select(.issue == "ENG-120") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng120_outcome" = "in_review" ]
  local eng121_outcome; eng121_outcome="$(jq -r '.[] | select(.issue == "ENG-121") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng121_outcome" = "in_review" ]
  local eng122_outcome; eng122_outcome="$(jq -r '.[] | select(.issue == "ENG-122") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng122_outcome" = "in_review" ]

  # A warning was emitted to stderr for the skipped map build
  [[ "$output" == *"failed to fetch blockers for ENG-120"* ]]
}

# ---------------------------------------------------------------------------
# 14. P2: linear_get_issue_branch returning literal "null" is treated as missing
# ---------------------------------------------------------------------------
@test "linear_get_issue_branch returns literal \"null\": outcome=setup_failed, step=missing_branch_name, no worktree" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # `jq -r '.branchName'` on an issue whose branchName field is missing emits
  # the literal string "null". Simulate that directly.
  export STUB_BRANCH_ENG_130="null"
  export STUB_BLOCKERS_ENG_130='[]'

  local q; q="$(write_queue ENG-130)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # claude was NOT invoked — setup failed before dispatch
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 0 ]

  # No worktree was created for the "null" branch
  [ ! -d "$REPO_DIR/.worktrees/null" ]

  # progress.json records setup_failed with step=missing_branch_name
  local outcome; outcome="$(jq -r '.[0].outcome' < "$REPO_DIR/progress.json")"
  [ "$outcome" = "setup_failed" ]
  local step; step="$(jq -r '.[0].failed_step' < "$REPO_DIR/progress.json")"
  [ "$step" = "missing_branch_name" ]

  # ralph-failed label was added
  grep -qF "add_label ENG-130 ralph-failed" "$STUB_LINEAR_CALLS_FILE"
}

# ---------------------------------------------------------------------------
# 15. P1: linear_set_state failure AFTER worktree creation cleans up worktree
#     and branch so the next run isn't blocked by a stale branch.
# ---------------------------------------------------------------------------
@test "linear_set_state fails after worktree creation: worktree + branch removed, next run unblocked" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  export STUB_SET_STATE_FAIL_ENG_140=1
  export STUB_BLOCKERS_ENG_140='[]'

  local q; q="$(write_queue ENG-140)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # claude was NOT invoked — setup failed at linear_set_state
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 0 ]

  # progress.json records setup_failed with step=linear_set_state
  local outcome; outcome="$(jq -r '.[0].outcome' < "$REPO_DIR/progress.json")"
  [ "$outcome" = "setup_failed" ]
  local step; step="$(jq -r '.[0].failed_step' < "$REPO_DIR/progress.json")"
  [ "$step" = "linear_set_state" ]

  # The worktree directory was removed so a re-run can recreate it
  [ ! -d "$REPO_DIR/.worktrees/eng-140" ]

  # The branch was deleted, so `git worktree add -b eng-140 ...` won't collide
  ! git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/eng-140"
}

# ---------------------------------------------------------------------------
# 16. P2: post-dispatch linear_get_issue_state failure does not abort the
#     orchestrator; the issue is classified as exit_clean_no_review and the
#     loop continues to the next issue.
# ---------------------------------------------------------------------------
@test "post-dispatch linear_get_issue_state fails: classified exit_clean_no_review, loop continues" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # Make the post-dispatch state fetch fail for ENG-150 but not ENG-151.
  export STUB_GET_STATE_FAIL_ENG_150=1
  export STUB_BLOCKERS_ENG_150='[]'
  export STUB_BLOCKERS_ENG_151='[]'

  # Per-issue transition stub so ENG-151 can land in In Review cleanly.
  cat > "$STUB_DIR/claude" <<'CLAUDESH'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$STUB_CLAUDE_ARGS_FILE"
printf '\n' >> "$STUB_CLAUDE_ARGS_FILE"
issue_id=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--name" ]]; then
    shift
    issue_id="${1%%:*}"
    break
  fi
  shift
done
if [[ -n "${STUB_CLAUDE_TRANSITION_STATE:-}" && -n "$issue_id" ]]; then
  printf '%s' "$STUB_CLAUDE_TRANSITION_STATE" > "$STUB_DIR/linear_state_$issue_id"
fi
exit 0
CLAUDESH
  chmod +x "$STUB_DIR/claude"

  local q; q="$(write_queue ENG-150 ENG-151)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # Both issues were dispatched — the state-lookup failure did not abort
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 2 ]

  # ENG-150: exit 0 + unknown state -> exit_clean_no_review + ralph-failed label
  local eng150_outcome; eng150_outcome="$(jq -r '.[] | select(.issue == "ENG-150") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng150_outcome" = "exit_clean_no_review" ]
  grep -qF "add_label ENG-150 ralph-failed" "$STUB_LINEAR_CALLS_FILE"

  # ENG-151: normal in_review path still works
  local eng151_outcome; eng151_outcome="$(jq -r '.[] | select(.issue == "ENG-151") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng151_outcome" = "in_review" ]

  # Warning was emitted for the state-fetch failure
  [[ "$output" == *"failed to fetch post-dispatch state for ENG-150"* ]]
}

# ---------------------------------------------------------------------------
# 17. P2: post-dispatch linear_add_label failure does not abort the
#     orchestrator; the outcome is still recorded and the loop continues.
# ---------------------------------------------------------------------------
@test "post-dispatch linear_add_label fails: warning emitted, outcome recorded, loop continues" {
  export STUB_CLAUDE_EXIT=9
  # No transition; hard failure -> orchestrator tries to add ralph-failed label
  export STUB_ADD_LABEL_FAIL_ENG_160=1
  export STUB_BLOCKERS_ENG_160='[]'
  export STUB_BLOCKERS_ENG_161='[]'

  cat > "$STUB_DIR/claude" <<'CLAUDESH'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$STUB_CLAUDE_ARGS_FILE"
printf '\n' >> "$STUB_CLAUDE_ARGS_FILE"
issue_id=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--name" ]]; then
    shift
    issue_id="${1%%:*}"
    break
  fi
  shift
done
case "$issue_id" in
  ENG-160) exit 9 ;;
  ENG-161) printf 'In Review' > "$STUB_DIR/linear_state_$issue_id"; exit 0 ;;
  *) exit 1 ;;
esac
CLAUDESH
  chmod +x "$STUB_DIR/claude"

  local q; q="$(write_queue ENG-160 ENG-161)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # Both were dispatched — the label-add failure for ENG-160 did not abort
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 2 ]

  # ENG-160 still recorded as failed, even though labeling errored
  local eng160_outcome; eng160_outcome="$(jq -r '.[] | select(.issue == "ENG-160") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng160_outcome" = "failed" ]

  # ENG-161 unaffected
  local eng161_outcome; eng161_outcome="$(jq -r '.[] | select(.issue == "ENG-161") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng161_outcome" = "in_review" ]

  # Warning was emitted for the failed label call
  [[ "$output" == *"failed to add ralph-failed label to ENG-160"* ]]
}

# ---------------------------------------------------------------------------
# 18. P1: integration-path worktree helper failing AFTER `git worktree add`
#     succeeds (e.g. a non-conflict merge error) must clean up the partial
#     worktree and branch so the next run isn't blocked. Outcome=setup_failed.
# ---------------------------------------------------------------------------
@test "integration worktree helper fails post-add (non-conflict merge error): worktree + branch cleaned up, outcome=setup_failed" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # Build an unrelated-histories parent: `git merge` refuses to merge it
  # (exit 128, no unmerged files), which is the non-conflict failure path
  # inside worktree_create_with_integration. By that point `git worktree add`
  # has already created the worktree + branch.
  git -C "$REPO_DIR" checkout --orphan eng-170-unrelated -q
  git -C "$REPO_DIR" rm -rf . 2>/dev/null || true
  echo "u" > "$REPO_DIR/u.txt"
  git -C "$REPO_DIR" add u.txt
  git -C "$REPO_DIR" commit -m "unrelated" -q
  git -C "$REPO_DIR" checkout main -q

  export STUB_DAG_BASE_ENG_170="INTEGRATION eng-170-unrelated"
  export STUB_BLOCKERS_ENG_170='[]'

  local q; q="$(write_queue ENG-170)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # claude was NOT invoked — setup failed at worktree_create_with_integration
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 0 ]

  # progress.json records setup_failed with step=worktree_create_with_integration
  local outcome; outcome="$(jq -r '.[0].outcome' < "$REPO_DIR/progress.json")"
  [ "$outcome" = "setup_failed" ]
  local step; step="$(jq -r '.[0].failed_step' < "$REPO_DIR/progress.json")"
  [ "$step" = "worktree_create_with_integration" ]

  # The partial worktree directory was cleaned up
  [ ! -d "$REPO_DIR/.worktrees/eng-170" ]

  # The branch was deleted so a re-run can recreate it
  ! git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/eng-170"

  # ralph-failed label was added
  grep -qF "add_label ENG-170 ralph-failed" "$STUB_LINEAR_CALLS_FILE"
}

# ---------------------------------------------------------------------------
# 19. P1: when `git worktree add -b` fails because the branch already exists,
#     cleanup MUST NOT delete that pre-existing branch (it may carry work
#     from a prior incomplete run). `git worktree add -b` is atomic: if the
#     worktree directory wasn't created, no new branch was created either.
# ---------------------------------------------------------------------------
@test "worktree_create_at_base fails due to pre-existing branch: pre-existing branch preserved, no worktree created" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # Pre-create the branch with a commit that represents unsaved prior work.
  # The branch's tip SHA must survive cleanup unchanged.
  git -C "$REPO_DIR" branch eng-180
  git -C "$REPO_DIR" checkout eng-180 -q
  echo "prior work" > "$REPO_DIR/prior.txt"
  git -C "$REPO_DIR" add prior.txt
  git -C "$REPO_DIR" commit -m "prior work on eng-180" -q
  local prior_sha; prior_sha="$(git -C "$REPO_DIR" rev-parse eng-180)"
  git -C "$REPO_DIR" checkout main -q

  export STUB_BLOCKERS_ENG_180='[]'

  local q; q="$(write_queue ENG-180)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # claude was NOT invoked — setup failed at worktree_create_at_base
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 0 ]

  # progress.json records setup_failed with step=worktree_create_at_base
  local outcome; outcome="$(jq -r '.[0].outcome' < "$REPO_DIR/progress.json")"
  [ "$outcome" = "setup_failed" ]
  local step; step="$(jq -r '.[0].failed_step' < "$REPO_DIR/progress.json")"
  [ "$step" = "worktree_create_at_base" ]

  # No worktree directory was created at the target path
  [ ! -d "$REPO_DIR/.worktrees/eng-180" ]

  # CRITICAL: the pre-existing branch STILL EXISTS — cleanup must not have
  # touched it. If this fails, _cleanup_worktree destroyed unsaved work.
  git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/eng-180"
  local post_sha; post_sha="$(git -C "$REPO_DIR" rev-parse eng-180)"
  [ "$post_sha" = "$prior_sha" ]
}

# ---------------------------------------------------------------------------
# 20. P1: when the target worktree path already exists before orchestrator
#     runs (stale dir from a crashed run, manual mkdir, etc.), `git worktree
#     add` fails without creating new state. Cleanup MUST NOT delete the
#     pre-existing directory — only state this invocation created.
# ---------------------------------------------------------------------------
@test "worktree path pre-exists before run: pre-existing dir preserved (marker file intact)" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # Pre-create the worktree target path with a marker file that represents
  # unsaved contents the operator left behind (or a prior crashed run).
  mkdir -p "$REPO_DIR/.worktrees/eng-190"
  echo "do not destroy" > "$REPO_DIR/.worktrees/eng-190/marker.txt"

  export STUB_BLOCKERS_ENG_190='[]'

  local q; q="$(write_queue ENG-190)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # claude was NOT invoked — setup failed at worktree_create_at_base
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 0 ]

  # progress.json records setup_failed with step=worktree_create_at_base
  local outcome; outcome="$(jq -r '.[0].outcome' < "$REPO_DIR/progress.json")"
  [ "$outcome" = "setup_failed" ]
  local step; step="$(jq -r '.[0].failed_step' < "$REPO_DIR/progress.json")"
  [ "$step" = "worktree_create_at_base" ]

  # CRITICAL: the pre-existing directory and its contents are UNTOUCHED.
  [ -d "$REPO_DIR/.worktrees/eng-190" ]
  [ -f "$REPO_DIR/.worktrees/eng-190/marker.txt" ]
  local marker_contents; marker_contents="$(cat "$REPO_DIR/.worktrees/eng-190/marker.txt")"
  [ "$marker_contents" = "do not destroy" ]
}
