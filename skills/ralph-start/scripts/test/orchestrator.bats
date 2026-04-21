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
  export RALPH_PROJECTS="Test Project"
  export RALPH_APPROVED_STATE="Approved"
  export RALPH_IN_PROGRESS_STATE="In Progress"
  export RALPH_REVIEW_STATE="In Review"
  export RALPH_DONE_STATE="Done"
  export RALPH_FAILED_LABEL="ralph-failed"
  export RALPH_WORKTREE_BASE=".worktrees"
  export RALPH_MODEL="opus"
  export RALPH_STDOUT_LOG="ralph-output.log"
  # Touch a dummy config and point RALPH_CONFIG at it. The marker carries the
  # tuple "<resolved-config>|<repo-root>" (ENG-205 scope gate); the
  # orchestrator is invoked with cwd=REPO_DIR so repo-root resolves to that.
  local dummy="$STUB_DIR/dummy-config.json"
  touch "$dummy"
  export RALPH_CONFIG="$dummy"
  export RALPH_CONFIG_LOADED="$(cd "$(dirname "$dummy")" && pwd)/$(basename "$dummy")|$REPO_DIR"

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

# Like run_orch but invokes orchestrator from a caller-specified working
# directory. Used to verify cwd-agnostic behaviors (e.g. progress.json is
# anchored to the repo root, not $PWD).
run_orch_from() {
  local cwd="$1" queue_file="$2"
  run bash -c "cd '$cwd' && '$STUB_DIR/scripts/orchestrator.sh' '$queue_file'"
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

  # claude was invoked with /ralph-implement as the dispatch prompt
  # (printf '%q' escapes the space as '\ ' in the args file)
  grep -qF '/ralph-implement\ ENG-10' "$STUB_CLAUDE_ARGS_FILE"

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
# 11. I1: per-issue fault isolation — a pre-existing branch (local residue
#     from a prior run, manual creation, etc.) does NOT abort the loop and
#     does NOT taint downstream dependents. Linear is left untouched for the
#     residue issue; downstream and independent issues dispatch normally.
# ---------------------------------------------------------------------------
@test "branch already exists at start of run: outcome=local_residue, downstream NOT tainted, loop continues" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # Pre-create the branch for ENG-100 (local residue).
  git -C "$REPO_DIR" branch eng-100

  # ENG-101 depends on ENG-100; ENG-102 is independent. ENG-100 is "Approved"
  # in ENG-101's blocker list (so dag_base for ENG-101 does not include
  # ENG-100's branch — ENG-101 dispatches with base=main).
  export STUB_BLOCKERS_ENG_100='[]'
  export STUB_BLOCKERS_ENG_101='[{"id":"ENG-100","state":"Approved","branch":"eng-100"}]'
  export STUB_BLOCKERS_ENG_102='[]'

  # Use the smart per-issue stub so each dispatched issue transitions correctly.
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

  # claude was invoked for ENG-101 and ENG-102 — ENG-100 was skipped (residue),
  # ENG-101 was NOT tainted, ENG-102 was independent.
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 2 ]
  grep -qF "ENG-101" "$STUB_CLAUDE_ARGS_FILE"
  grep -qF "ENG-102" "$STUB_CLAUDE_ARGS_FILE"
  ! grep -qF "ENG-100:" "$STUB_CLAUDE_ARGS_FILE"

  # NO ralph-failed label for ENG-100 — local residue must not mutate Linear.
  ! grep -q "add_label ENG-100" "$STUB_LINEAR_CALLS_FILE"

  # progress.json has three records
  local records; records="$(jq 'length' < "$REPO_DIR/progress.json")"
  [ "$records" -eq 3 ]

  local eng100_outcome; eng100_outcome="$(jq -r '.[] | select(.issue == "ENG-100") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng100_outcome" = "local_residue" ]

  local eng101_outcome; eng101_outcome="$(jq -r '.[] | select(.issue == "ENG-101") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng101_outcome" = "in_review" ]

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
# 16. P2: post-dispatch linear_get_issue_state failure does NOT collapse to
#     exit_clean_no_review (codex adversarial review, finding B). A transient
#     state-read failure after a successful claude session would otherwise
#     mislabel a true success as ralph-failed and taint downstream. Classify
#     as unknown_post_state with NO label and NO descendant taint; operator
#     disambiguates from progress.json + Linear UI.
# ---------------------------------------------------------------------------
@test "post-dispatch linear_get_issue_state fails: classified unknown_post_state, no label, no taint, loop continues" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # Make the post-dispatch state fetch fail for ENG-150. Claude's stub still
  # transitions the state (so the "real" state IS In Review) — the read path
  # is the thing that fails, simulating a transient Linear API blip after
  # a successful session.
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

  # ENG-150: state-fetch failure -> unknown_post_state, NO label, NO taint
  local eng150_outcome; eng150_outcome="$(jq -r '.[] | select(.issue == "ENG-150") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng150_outcome" = "unknown_post_state" ]
  ! grep -qF "add_label ENG-150 ralph-failed" "$STUB_LINEAR_CALLS_FILE"

  # ENG-150 record carries dispatch metadata (branch, base, exit_code, duration)
  local eng150_branch; eng150_branch="$(jq -r '.[] | select(.issue == "ENG-150") | .branch' < "$REPO_DIR/progress.json")"
  [ "$eng150_branch" = "eng-150" ]
  local eng150_exit; eng150_exit="$(jq -r '.[] | select(.issue == "ENG-150") | .exit_code' < "$REPO_DIR/progress.json")"
  [ "$eng150_exit" = "0" ]

  # ENG-151: normal in_review path still works
  local eng151_outcome; eng151_outcome="$(jq -r '.[] | select(.issue == "ENG-151") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng151_outcome" = "in_review" ]

  # Warning was emitted for the state-fetch failure
  [[ "$output" == *"failed to fetch post-dispatch state for ENG-150"* ]]
}

# ---------------------------------------------------------------------------
# 16b. unknown_post_state must NOT taint downstream dependents — a degraded
#      read after a (possibly real) success should not block a chain.
# ---------------------------------------------------------------------------
@test "unknown_post_state does not taint downstream dependents" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # ENG-152 is blocked by ENG-150 — state fetch fails for ENG-150
  export STUB_GET_STATE_FAIL_ENG_150=1
  export STUB_BLOCKERS_ENG_150='[]'
  export STUB_BLOCKERS_ENG_152='[{"id":"ENG-150","state":"Approved","branch":"eng-150"}]'

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

  local q; q="$(write_queue ENG-150 ENG-152)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # ENG-150 -> unknown_post_state
  local eng150_outcome; eng150_outcome="$(jq -r '.[] | select(.issue == "ENG-150") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng150_outcome" = "unknown_post_state" ]

  # ENG-152 was NOT skipped — it dispatched normally
  local eng152_outcome; eng152_outcome="$(jq -r '.[] | select(.issue == "ENG-152") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng152_outcome" != "skipped" ]
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 2 ]
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
# 19. P1: when the target branch already exists at the start of a run, the
#     orchestrator records a local_residue outcome and skips dispatch WITHOUT
#     mutating Linear (no ralph-failed label, no descendant taint) — codex
#     adversarial review, finding A. The pre-existing branch must survive
#     unchanged (no destructive cleanup).
# ---------------------------------------------------------------------------
@test "branch already exists at start of run: outcome=local_residue, no Linear mutation, branch preserved" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # Pre-create the branch with a commit that represents unsaved prior work.
  # The branch's tip SHA must survive unchanged.
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

  # claude was NOT invoked — pre-flight detected the residue
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 0 ]

  # progress.json records local_residue with the residue path and branch
  local outcome; outcome="$(jq -r '.[0].outcome' < "$REPO_DIR/progress.json")"
  [ "$outcome" = "local_residue" ]
  local residue_branch; residue_branch="$(jq -r '.[0].residue_branch' < "$REPO_DIR/progress.json")"
  [ "$residue_branch" = "eng-180" ]

  # Linear was NOT mutated — no add_label call, no set_state call
  ! grep -q "add_label ENG-180" "$STUB_LINEAR_CALLS_FILE"
  ! grep -q "set_state ENG-180" "$STUB_LINEAR_CALLS_FILE"

  # No worktree directory was created at the target path
  [ ! -d "$REPO_DIR/.worktrees/eng-180" ]

  # CRITICAL: the pre-existing branch STILL EXISTS unchanged.
  git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/eng-180"
  local post_sha; post_sha="$(git -C "$REPO_DIR" rev-parse eng-180)"
  [ "$post_sha" = "$prior_sha" ]
}

# ---------------------------------------------------------------------------
# 20. P1: when the target worktree path already exists at the start of a run
#     (stale dir from a crashed run, manual mkdir, etc.), the orchestrator
#     records local_residue and skips dispatch WITHOUT mutating Linear or
#     touching the pre-existing directory contents — codex adversarial
#     review, finding A.
# ---------------------------------------------------------------------------
@test "worktree path pre-exists at start of run: outcome=local_residue, no Linear mutation, dir preserved" {
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

  # claude was NOT invoked — pre-flight detected the residue
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 0 ]

  # progress.json records local_residue with the residue path
  local outcome; outcome="$(jq -r '.[0].outcome' < "$REPO_DIR/progress.json")"
  [ "$outcome" = "local_residue" ]
  local residue_path; residue_path="$(jq -r '.[0].residue_path' < "$REPO_DIR/progress.json")"
  [ "$residue_path" = "$REPO_DIR/.worktrees/eng-190" ]

  # Linear was NOT mutated — no add_label call, no set_state call
  ! grep -q "add_label ENG-190" "$STUB_LINEAR_CALLS_FILE"
  ! grep -q "set_state ENG-190" "$STUB_LINEAR_CALLS_FILE"

  # CRITICAL: the pre-existing directory and its contents are UNTOUCHED.
  [ -d "$REPO_DIR/.worktrees/eng-190" ]
  [ -f "$REPO_DIR/.worktrees/eng-190/marker.txt" ]
  local marker_contents; marker_contents="$(cat "$REPO_DIR/.worktrees/eng-190/marker.txt")"
  [ "$marker_contents" = "do not destroy" ]
}

# ---------------------------------------------------------------------------
# 20b. local_residue must NOT taint downstream dependents — operator will
#      clean up the residue and re-run, at which point the normal dispatch
#      path will execute.
# ---------------------------------------------------------------------------
@test "local_residue does not taint downstream dependents" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # ENG-192 is blocked by ENG-191; ENG-191's branch already exists (residue).
  git -C "$REPO_DIR" branch eng-191
  export STUB_BLOCKERS_ENG_191='[]'
  export STUB_BLOCKERS_ENG_192='[{"id":"ENG-191","state":"Approved","branch":"eng-191"}]'

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

  local q; q="$(write_queue ENG-191 ENG-192)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # ENG-191 -> local_residue
  local eng191_outcome; eng191_outcome="$(jq -r '.[] | select(.issue == "ENG-191") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng191_outcome" = "local_residue" ]

  # ENG-192 was NOT skipped — taint did not propagate
  local eng192_outcome; eng192_outcome="$(jq -r '.[] | select(.issue == "ENG-192") | .outcome' < "$REPO_DIR/progress.json")"
  [ "$eng192_outcome" != "skipped" ]
}

# ---------------------------------------------------------------------------
# 21. run_id: every record from a single orchestrator invocation shares the
#     same run_id (groups records for auditing — design Component 6).
# ---------------------------------------------------------------------------
@test "run_id: all records from a single run share the same run_id" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # Smart per-issue transition stub so all three issues reach in_review.
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

  local q; q="$(write_queue ENG-200 ENG-201 ENG-202)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  local records; records="$(jq 'length' < "$REPO_DIR/progress.json")"
  [ "$records" -eq 3 ]

  # All three records carry a non-empty run_id
  local null_run_ids; null_run_ids="$(jq '[.[] | select(.run_id == null or .run_id == "")] | length' < "$REPO_DIR/progress.json")"
  [ "$null_run_ids" -eq 0 ]

  # All run_ids are identical within a single run
  local distinct_run_ids; distinct_run_ids="$(jq '[.[].run_id] | unique | length' < "$REPO_DIR/progress.json")"
  [ "$distinct_run_ids" -eq 1 ]

  # run_id matches the ISO 8601 UTC format produced by date -u +%Y-%m-%dT%H:%M:%SZ
  local sample; sample="$(jq -r '.[0].run_id' < "$REPO_DIR/progress.json")"
  [[ "$sample" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# ---------------------------------------------------------------------------
# 22. run_id: running the orchestrator twice against the same progress.json
#     produces two distinct run_ids, and both runs' records survive (the
#     atomic tmpfile+mv append preserves prior contents).
# ---------------------------------------------------------------------------
@test "run_id: two consecutive orchestrator runs append with distinct run_ids, prior records preserved" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

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

  # First run: ENG-210
  local q1; q1="$(write_queue ENG-210)"
  run_orch "$q1"
  [ "$status" -eq 0 ]

  # Sleep 1s to guarantee date -u +%...%SZ produces a different second.
  # run_id is second-resolution by design; back-to-back runs within the
  # same second would share an id, which is fine semantically but defeats
  # this test's ability to distinguish the two invocations.
  sleep 1

  # Second run: ENG-211 (fresh queue, same progress.json)
  local q2; q2="$(write_queue ENG-211)"
  run_orch "$q2"
  [ "$status" -eq 0 ]

  # Both runs' records are present
  local records; records="$(jq 'length' < "$REPO_DIR/progress.json")"
  [ "$records" -eq 2 ]

  # Extract each issue's run_id
  local run_id_210; run_id_210="$(jq -r '.[] | select(.issue == "ENG-210") | .run_id' < "$REPO_DIR/progress.json")"
  local run_id_211; run_id_211="$(jq -r '.[] | select(.issue == "ENG-211") | .run_id' < "$REPO_DIR/progress.json")"

  [ -n "$run_id_210" ]
  [ -n "$run_id_211" ]
  [ "$run_id_210" != "$run_id_211" ]
}

# ---------------------------------------------------------------------------
# 23. atomicity: no progress.json.* tmpfiles remain after orchestrator exits.
#     The mktemp+jq+mv path must consume every temp file it creates —
#     leftover tmpfiles would indicate a crashed write or a missing mv.
# ---------------------------------------------------------------------------
@test "atomicity: no progress.json tmpfiles linger in cwd after orchestrator exits" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

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

  local q; q="$(write_queue ENG-220 ENG-221 ENG-222)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # progress.json exists; no progress.json.XXXXXX tmpfiles remain
  [ -f "$REPO_DIR/progress.json" ]
  local leftover_count
  leftover_count="$(find "$REPO_DIR" -maxdepth 1 -name 'progress.json.*' -type f | wc -l | tr -d ' ')"
  [ "$leftover_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 24. progress.json must land at the repo root, not $PWD. Invoking from a
#     subdirectory or a linked worktree would otherwise bury the audit log
#     in a transient location (linked worktrees are created and removed by
#     ralph itself) and silently discard recovery state.
# ---------------------------------------------------------------------------
@test "progress.json anchored to repo root when orchestrator invoked from subdirectory" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"
  export STUB_CLAUDE_ISSUE_ID="ENG-10"

  local subdir="$REPO_DIR/nested/deep"
  mkdir -p "$subdir"

  local q; q="$(write_queue ENG-10)"
  run_orch_from "$subdir" "$q"

  [ "$status" -eq 0 ]

  # progress.json lives at the repo root, not in the invocation subdirectory
  [ -f "$REPO_DIR/progress.json" ]
  [ ! -f "$subdir/progress.json" ]
  local count; count="$(jq 'length' < "$REPO_DIR/progress.json")"
  [ "$count" -eq 1 ]
}
