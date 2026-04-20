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
  printf '%s' "$state" > "$STUB_DIR/linear_state_$issue_id"
}

linear_add_label() {
  local issue_id="$1"
  local label="$2"
  printf 'add_label %s %s\n' "$issue_id" "$label" >> "$STUB_LINEAR_CALLS_FILE"
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
