#!/usr/bin/env bats
# Tests for scripts/orchestrator.sh
# Stubs lib/linear.sh (fake functions), dag_base.sh, and the `claude` CLI
# via a mirrored temp directory layout so orchestrator sources the fakes.
# Uses a real throwaway git repo so worktree operations run for real.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ORCH_SH="$SCRIPT_DIR/orchestrator.sh"
DIAGNOSE_SH="$SCRIPT_DIR/diagnose_session.sh"
WORKTREE_SH="$(cd "$SCRIPT_DIR/../../.." && pwd)/lib/worktree.sh"
AUTONOMOUS_PREAMBLE="$SCRIPT_DIR/autonomous-preamble.md"

# ---------------------------------------------------------------------------
# Setup: real git repo + STUB_DIR with mirrored scripts/ layout
# ---------------------------------------------------------------------------
setup() {
  STUB_DIR="$(cd "$(mktemp -d)" && pwd -P)"
  export STUB_DIR
  # $STUB_DIR doubles as the stub plugin root. Moved libs (defaults.sh,
  # linear.sh) live under $STUB_DIR/lib/; sr-start-only worktree.sh stays
  # under $STUB_DIR/scripts/lib/, where $SCRIPT_DIR/lib/worktree.sh resolves
  # when orchestrator.sh runs from $STUB_DIR/scripts/.
  export CLAUDE_PLUGIN_ROOT="$STUB_DIR"

  REPO_DIR="$(cd "$(mktemp -d)" && pwd -P)"
  export REPO_DIR
  git -C "$REPO_DIR" init -b main -q
  git -C "$REPO_DIR" config user.email "t@t.com"
  git -C "$REPO_DIR" config user.name "t"
  git -C "$REPO_DIR" commit --allow-empty -m "init" -q

  # Env vars the plugin harness exports from userConfig. SENSIBLE_RALPH_PROJECTS is
  # the per-repo scope var (from lib/scope.sh, not userConfig).
  export SENSIBLE_RALPH_PROJECTS="Test Project"
  export CLAUDE_PLUGIN_OPTION_APPROVED_STATE="Approved"
  export CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE="In Progress"
  export CLAUDE_PLUGIN_OPTION_REVIEW_STATE="In Review"
  export CLAUDE_PLUGIN_OPTION_DONE_STATE="Done"
  export CLAUDE_PLUGIN_OPTION_FAILED_LABEL="ralph-failed"
  export CLAUDE_PLUGIN_OPTION_WORKTREE_BASE=".worktrees"
  export CLAUDE_PLUGIN_OPTION_MODEL="opus"
  export CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME="ralph-output.log"
  # Set the scope-loaded marker so orchestrator.sh's auto-source gate skips
  # loading scope.sh. The orchestrator is invoked with cwd=REPO_DIR so
  # repo-root resolves to that.
  local _scope_hash=""
  if [[ -f "$REPO_DIR/.sensible-ralph.json" ]]; then
    _scope_hash="$(shasum -a 1 < "$REPO_DIR/.sensible-ralph.json" | awk '{print $1}')"
  fi
  export SENSIBLE_RALPH_SCOPE_LOADED="$REPO_DIR|$_scope_hash"
  # ENG-214: orchestrator's INTEGRATION path reads SENSIBLE_RALPH_DEFAULT_BASE_BRANCH
  # (formerly hardcoded to "main"). With the marker bypass above, scope.sh
  # is never sourced, so tests must export the trunk explicitly.
  export SENSIBLE_RALPH_DEFAULT_BASE_BRANCH="main"

  # Claude invocation capture + state-transition trace
  export STUB_CLAUDE_ARGS_FILE="$STUB_DIR/claude_args"
  : > "$STUB_CLAUDE_ARGS_FILE"
  # ENG-337: capture child's CLAUDE_CONFIG_DIR set-ness + value, one line per
  # invocation. Format: `unset` when not in env, `set:<value>` when in env
  # (empty value renders as `set:`). Lets tests distinguish "parent had it
  # set to default" from "parent had it unset" — distinct because claude's
  # auth-resolution path branches on set-ness, not value.
  export STUB_CLAUDE_ENV_CONFIG_DIR_FILE="$STUB_DIR/claude_env_config_dir"
  : > "$STUB_CLAUDE_ENV_CONFIG_DIR_FILE"
  export STUB_LINEAR_CALLS_FILE="$STUB_DIR/linear_calls"
  : > "$STUB_LINEAR_CALLS_FILE"

  # Stub layout:
  #   $STUB_DIR/lib/{defaults,linear,worktree}.sh      — plugin-wide libs
  #   $STUB_DIR/scripts/{orchestrator,dag_base}.sh     — entry-point scripts
  mkdir -p "$STUB_DIR/lib"
  mkdir -p "$STUB_DIR/scripts"
  cp "$ORCH_SH" "$STUB_DIR/scripts/orchestrator.sh"
  # ENG-308 diagnose helper. Orchestrator invokes it on non-success outcomes.
  cp "$DIAGNOSE_SH" "$STUB_DIR/scripts/diagnose_session.sh"
  chmod +x "$STUB_DIR/scripts/diagnose_session.sh"
  # Real worktree.sh — we want real git worktree operations
  cp "$WORKTREE_SH" "$STUB_DIR/lib/worktree.sh"
  # defaults.sh is sourced from $CLAUDE_PLUGIN_ROOT/lib for CLAUDE_PLUGIN_OPTION_* fallbacks
  cp "$SCRIPT_DIR/../../../lib/defaults.sh" "$STUB_DIR/lib/defaults.sh"
  # orchestrator.sh prepends this file to the claude -p prompt
  cp "$AUTONOMOUS_PREAMBLE" "$STUB_DIR/scripts/autonomous-preamble.md"

  # Fake lib/linear.sh driven by env vars / fixture files.
  # Also records every call (function + args) to $STUB_LINEAR_CALLS_FILE.
  cat > "$STUB_DIR/lib/linear.sh" <<'LINEARSH'
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
  # ENG-322: fail only on the post-dispatch revert call (state ==
  # CLAUDE_PLUGIN_OPTION_APPROVED_STATE), so the dispatch-time In Progress
  # transition still succeeds. Used by partial-write tests that exercise
  # the labeled-In-Progress (revert API blip) recovery path.
  local revert_fail_var="STUB_SET_STATE_FAIL_ON_REVERT_${key}"
  if [[ -n "${!revert_fail_var:-}" && "$state" == "${CLAUDE_PLUGIN_OPTION_APPROVED_STATE:-Approved}" ]]; then
    printf 'stub: linear_set_state failed on revert for %s\n' "$issue_id" >&2
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

# ENG-322: post-add label verification stub. Reads STUB_LABELS_<KEY> (newline-
# separated label names) and writes them to stdout. Default empty (no labels
# observed — simulates Linear's silent-no-op when the workspace label is
# missing). STUB_GET_LABELS_FAIL_<KEY> set => returns non-zero with a
# diagnostic to stderr (simulates a transient `linear issue view` blip).
# The stub is deliberately decoupled from linear_add_label so tests express
# the silent-no-op scenario by setting label-add success and STUB_LABELS empty.
linear_get_issue_labels() {
  local issue_id="$1"
  printf 'get_labels %s\n' "$issue_id" >> "$STUB_LINEAR_CALLS_FILE"
  local key; key="$(_issue_var "$issue_id")"
  local fail_var="STUB_GET_LABELS_FAIL_${key}"
  if [[ -n "${!fail_var:-}" ]]; then
    printf 'stub: linear_get_issue_labels failed for %s\n' "$issue_id" >&2
    return 1
  fi
  local var="STUB_LABELS_${key}"
  printf '%s' "${!var:-}"
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
    printf '%s' "${CLAUDE_PLUGIN_OPTION_APPROVED_STATE:-Approved}"
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

  # Stub claude via PATH. Records argv + inherited CLAUDE_CONFIG_DIR,
  # optionally transitions Linear state.
  cat > "$STUB_DIR/claude" <<'CLAUDESH'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$STUB_CLAUDE_ARGS_FILE"
printf '\n' >> "$STUB_CLAUDE_ARGS_FILE"
# ${VAR+set} (no colon) distinguishes unset from set-but-empty.
if [[ -z "${CLAUDE_CONFIG_DIR+set}" ]]; then
  printf 'unset\n' >> "$STUB_CLAUDE_ENV_CONFIG_DIR_FILE"
else
  printf 'set:%s\n' "$CLAUDE_CONFIG_DIR" >> "$STUB_CLAUDE_ENV_CONFIG_DIR_FILE"
fi
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

# Read $REPO_DIR/.sensible-ralph/progress.json records (jq-friendly).
progress_json() {
  cat "$REPO_DIR/.sensible-ralph/progress.json"
}

# ---------------------------------------------------------------------------
# 1. Clean single-issue success: exit 0 + state transitions to In Review
# ---------------------------------------------------------------------------
@test "single issue success: outcome=in_review, .sensible-ralph-base-sha present, Linear set to In Progress" {
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

  # Worktree exists; .sensible-ralph-base-sha is present and is a 40-char hex SHA
  local wt_path="$REPO_DIR/.worktrees/eng-10"
  [ -d "$wt_path" ]
  [ -f "$wt_path/.sensible-ralph-base-sha" ]
  local sha; sha="$(cat "$wt_path/.sensible-ralph-base-sha")"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]]

  # claude was invoked with /sr-implement as the dispatch prompt. The
  # orchestrator prepends the autonomous-mode preamble (which contains
  # non-ASCII bytes — em-dashes) and a blank line. printf '%q' on the
  # resulting multi-line arg wraps it in $'...' form where internal spaces
  # are NOT backslash-escaped. BSD grep in a UTF-8 locale silently refuses
  # to match when a file contains invalid UTF-8; LC_ALL=C forces byte-
  # oriented matching, and -a forces text mode.
  LC_ALL=C grep -qaF '/sr-implement ENG-10' "$STUB_CLAUDE_ARGS_FILE"

  # progress.json has exactly two records — one start, one end (in_review)
  [ -f "$REPO_DIR/.sensible-ralph/progress.json" ]
  local count; count="$(jq 'length' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$count" -eq 2 ]

  # Start record (index 0): event=start, issue/branch/base/timestamp/run_id populated
  local start_event; start_event="$(jq -r '.[0].event' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$start_event" = "start" ]
  local start_issue; start_issue="$(jq -r '.[0].issue' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$start_issue" = "ENG-10" ]
  local start_branch; start_branch="$(jq -r '.[0].branch' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$start_branch" = "eng-10" ]
  local start_base; start_base="$(jq -r '.[0].base' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$start_base" = "main" ]
  local start_ts; start_ts="$(jq -r '.[0].timestamp' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [[ "$start_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  local start_run; start_run="$(jq -r '.[0].run_id' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [[ "$start_run" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]

  # End record (index 1): event=end, outcome=in_review, same issue/run_id
  local end_event; end_event="$(jq -r '.[1].event' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$end_event" = "end" ]
  local outcome; outcome="$(jq -r '.[1].outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$outcome" = "in_review" ]
  local end_issue; end_issue="$(jq -r '.[1].issue' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$end_issue" = "ENG-10" ]
  local end_run; end_run="$(jq -r '.[1].run_id' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$end_run" = "$start_run" ]
}

# ---------------------------------------------------------------------------
# 1b. Autonomous-mode signal: SENSIBLE_RALPH_AUTONOMOUS=1 reaches claude env.
# /prepare-for-review's halt path (ENG-245) branches on this var; the
# contract is that the orchestrator exports it at the dispatch site.
# ---------------------------------------------------------------------------
@test "ENG-245 SENSIBLE_RALPH_AUTONOMOUS=1 is exported into claude subprocess env" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"
  export STUB_CLAUDE_ISSUE_ID="ENG-245TEST"

  # Replace the default stub with one that records the value of
  # SENSIBLE_RALPH_AUTONOMOUS as seen by claude.
  local autonomous_capture="$STUB_DIR/claude_autonomous_value"
  cat > "$STUB_DIR/claude" <<CLAUDESH
#!/usr/bin/env bash
printf '%s\n' "\${SENSIBLE_RALPH_AUTONOMOUS:-UNSET}" > "$autonomous_capture"
exit 0
CLAUDESH
  chmod +x "$STUB_DIR/claude"

  local q; q="$(write_queue ENG-245TEST)"
  run_orch "$q"

  [ "$status" -eq 0 ]
  [ -f "$autonomous_capture" ]
  local captured; captured="$(cat "$autonomous_capture")"
  [ "$captured" = "1" ]
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

  # 3 start + 3 end records = 6 total
  local count; count="$(jq 'length' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$count" -eq 6 ]
  local in_review_count; in_review_count="$(jq '[.[] | select(.event == "end" and .outcome == "in_review")] | length' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$in_review_count" -eq 3 ]
  local start_count; start_count="$(jq '[.[] | select(.event == "start")] | length' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$start_count" -eq 3 ]
}

# ---------------------------------------------------------------------------
# 3. Hard failure: exit non-zero -> ralph-failed label, outcome=failed
# ---------------------------------------------------------------------------
@test "hard failure: exit non-zero adds ralph-failed label, outcome=failed with exit_code" {
  export STUB_CLAUDE_EXIT=7
  # No state transition — session crashed
  # ENG-322: post-add verify reads the label list; setting STUB_LABELS_ENG_20
  # so the gate observes ralph-failed and the state-revert runs (happy path).
  export STUB_LABELS_ENG_20="ralph-failed"

  local q; q="$(write_queue ENG-20)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # ralph-failed label was added, verified, and state was reverted to Approved.
  grep -qF "add_label ENG-20 ralph-failed" "$STUB_LINEAR_CALLS_FILE"
  grep -qF "get_labels ENG-20" "$STUB_LINEAR_CALLS_FILE"
  grep -qF "set_state ENG-20 Approved" "$STUB_LINEAR_CALLS_FILE"

  # progress.json end record: outcome=failed with exit_code=7
  local outcome; outcome="$(jq -r '.[] | select(.issue == "ENG-20" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$outcome" = "failed" ]
  local exit_code; exit_code="$(jq -r '.[] | select(.issue == "ENG-20" and .event == "end") | .exit_code' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$exit_code" = "7" ]
}

# ---------------------------------------------------------------------------
# 4. Soft failure: exit 0 but state stayed at In Progress (Q2 case)
# ---------------------------------------------------------------------------
@test "soft failure: exit 0 without state transition adds ralph-failed, outcome=exit_clean_no_review" {
  export STUB_CLAUDE_EXIT=0
  # No STUB_CLAUDE_TRANSITION_STATE — stub won't move state beyond "In Progress"
  export STUB_LABELS_ENG_30="ralph-failed"

  local q; q="$(write_queue ENG-30)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  grep -qF "add_label ENG-30 ralph-failed" "$STUB_LINEAR_CALLS_FILE"
  grep -qF "get_labels ENG-30" "$STUB_LINEAR_CALLS_FILE"
  grep -qF "set_state ENG-30 Approved" "$STUB_LINEAR_CALLS_FILE"

  local outcome; outcome="$(jq -r '.[] | select(.issue == "ENG-30" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
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

  # progress.json: ENG-40 (start + end:failed), ENG-41 (end:skipped only — never dispatched)
  local end_records; end_records="$(jq '[.[] | select(.event == "end")] | length' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$end_records" -eq 2 ]
  local eng40_outcome; eng40_outcome="$(jq -r '.[] | select(.issue == "ENG-40" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$eng40_outcome" = "failed" ]
  local eng41_outcome; eng41_outcome="$(jq -r '.[] | select(.issue == "ENG-41" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
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

  local eng51_outcome; eng51_outcome="$(jq -r '.[] | select(.issue == "ENG-51" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
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

  local eng60_outcome; eng60_outcome="$(jq -r '.[] | select(.issue == "ENG-60" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$eng60_outcome" = "failed" ]
  local eng61_outcome; eng61_outcome="$(jq -r '.[] | select(.issue == "ENG-61" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
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

  local eng71_outcome; eng71_outcome="$(jq -r '.[] | select(.issue == "ENG-71" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$eng71_outcome" = "skipped" ]
  local eng72_outcome; eng72_outcome="$(jq -r '.[] | select(.issue == "ENG-72" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
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
  [ -f "$wt_path/.sensible-ralph-base-sha" ]
}

# ---------------------------------------------------------------------------
# 10. ENG-279 base-sha post-merge fix: integration mode now records the
#     post-merge HEAD (the worktree's HEAD after parents are merged in),
#     not the pre-merge trunk SHA. The codex review of impl commits stays
#     scoped to this session's work because parent commits become ancestors
#     of base-sha → excluded from prepare-for-review's diff.
# ---------------------------------------------------------------------------
@test "integration base records post-merge HEAD in .sensible-ralph-base-sha" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # Build a parent branch with real commits so merge produces a non-empty diff
  # and the post-merge HEAD differs from main.
  git -C "$REPO_DIR" checkout -b eng-90-parent-a -q
  echo "a" > "$REPO_DIR/a.txt"
  git -C "$REPO_DIR" add a.txt
  git -C "$REPO_DIR" commit -m "parent a" -q
  git -C "$REPO_DIR" checkout main -q

  local main_sha; main_sha="$(git -C "$REPO_DIR" rev-parse main)"

  export STUB_DAG_BASE_ENG_91="INTEGRATION eng-90-parent-a"
  export STUB_CLAUDE_ISSUE_ID="ENG-91"

  local q; q="$(write_queue ENG-91)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  local wt_path="$REPO_DIR/.worktrees/eng-91"
  [ -f "$wt_path/.sensible-ralph-base-sha" ]

  local recorded_sha; recorded_sha="$(cat "$wt_path/.sensible-ralph-base-sha")"
  local post_merge_sha; post_merge_sha="$(git -C "$wt_path" rev-parse HEAD)"

  # ENG-279: base-sha is post-merge HEAD (the merge commit). Parent commits
  # become ancestors of base-sha and are correctly excluded from the impl
  # diff in prepare-for-review.
  [ "$recorded_sha" = "$post_merge_sha" ]

  # Sanity: post-merge HEAD must differ from main (proves the merge happened)
  [ "$post_merge_sha" != "$main_sha" ]

  # Therefore recorded_sha must differ from main_sha
  [ "$recorded_sha" != "$main_sha" ]
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

  # progress.json: ENG-100 (end:local_residue), ENG-101 (start + end:in_review),
  # ENG-102 (start + end:in_review) = 3 end records, 2 start records.
  local end_records; end_records="$(jq '[.[] | select(.event == "end")] | length' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$end_records" -eq 3 ]

  local eng100_outcome; eng100_outcome="$(jq -r '.[] | select(.issue == "ENG-100" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$eng100_outcome" = "local_residue" ]

  local eng101_outcome; eng101_outcome="$(jq -r '.[] | select(.issue == "ENG-101" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$eng101_outcome" = "in_review" ]

  local eng102_outcome; eng102_outcome="$(jq -r '.[] | select(.issue == "ENG-102" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
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

  local eng110_outcome; eng110_outcome="$(jq -r '.[] | select(.issue == "ENG-110" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$eng110_outcome" = "setup_failed" ]

  local eng111_outcome; eng111_outcome="$(jq -r '.[] | select(.issue == "ENG-111" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
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

  local end_records; end_records="$(jq '[.[] | select(.event == "end")] | length' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$end_records" -eq 3 ]

  local eng120_outcome; eng120_outcome="$(jq -r '.[] | select(.issue == "ENG-120" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$eng120_outcome" = "in_review" ]
  local eng121_outcome; eng121_outcome="$(jq -r '.[] | select(.issue == "ENG-121" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$eng121_outcome" = "in_review" ]
  local eng122_outcome; eng122_outcome="$(jq -r '.[] | select(.issue == "ENG-122" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
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
  # ENG-322: verify-after-add gate runs in the setup_failed path too; STUB_LABELS
  # primes the post-add read so the helper observes the label and exits clean.
  export STUB_LABELS_ENG_130="ralph-failed"

  local q; q="$(write_queue ENG-130)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # claude was NOT invoked — setup failed before dispatch
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 0 ]

  # No worktree was created for the "null" branch
  [ ! -d "$REPO_DIR/.worktrees/null" ]

  # progress.json records setup_failed with step=missing_branch_name
  local event; event="$(jq -r '.[0].event' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$event" = "end" ]
  local outcome; outcome="$(jq -r '.[0].outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$outcome" = "setup_failed" ]
  local step; step="$(jq -r '.[0].failed_step' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$step" = "missing_branch_name" ]

  # ralph-failed label was added; verify-after-add gate ran (no state revert
  # in setup_failed — state is still Approved).
  grep -qF "add_label ENG-130 ralph-failed" "$STUB_LINEAR_CALLS_FILE"
  grep -qF "get_labels ENG-130" "$STUB_LINEAR_CALLS_FILE"
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
  local event; event="$(jq -r '.[0].event' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$event" = "end" ]
  local outcome; outcome="$(jq -r '.[0].outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$outcome" = "setup_failed" ]
  local step; step="$(jq -r '.[0].failed_step' < "$REPO_DIR/.sensible-ralph/progress.json")"
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
  local eng150_outcome; eng150_outcome="$(jq -r '.[] | select(.issue == "ENG-150" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$eng150_outcome" = "unknown_post_state" ]
  ! grep -qF "add_label ENG-150 ralph-failed" "$STUB_LINEAR_CALLS_FILE"

  # ENG-150 end record carries dispatch metadata (branch, base, exit_code, duration)
  local eng150_branch; eng150_branch="$(jq -r '.[] | select(.issue == "ENG-150" and .event == "end") | .branch' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$eng150_branch" = "eng-150" ]
  local eng150_exit; eng150_exit="$(jq -r '.[] | select(.issue == "ENG-150" and .event == "end") | .exit_code' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$eng150_exit" = "0" ]

  # ENG-151: normal in_review path still works
  local eng151_outcome; eng151_outcome="$(jq -r '.[] | select(.issue == "ENG-151" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
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
  local eng150_outcome; eng150_outcome="$(jq -r '.[] | select(.issue == "ENG-150" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$eng150_outcome" = "unknown_post_state" ]

  # ENG-152 was NOT skipped — it dispatched normally
  local eng152_outcome; eng152_outcome="$(jq -r '.[] | select(.issue == "ENG-152" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
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
  local eng160_outcome; eng160_outcome="$(jq -r '.[] | select(.issue == "ENG-160" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$eng160_outcome" = "failed" ]

  # ENG-161 unaffected
  local eng161_outcome; eng161_outcome="$(jq -r '.[] | select(.issue == "ENG-161" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
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
  # ENG-322: prime the verify-after-add gate's read so it observes the label.
  export STUB_LABELS_ENG_170="ralph-failed"

  local q; q="$(write_queue ENG-170)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # claude was NOT invoked — setup failed at worktree_create_with_integration
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 0 ]

  # progress.json records setup_failed with step=worktree_create_with_integration
  local event; event="$(jq -r '.[0].event' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$event" = "end" ]
  local outcome; outcome="$(jq -r '.[0].outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$outcome" = "setup_failed" ]
  local step; step="$(jq -r '.[0].failed_step' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$step" = "worktree_create_with_integration" ]

  # The partial worktree directory was cleaned up
  [ ! -d "$REPO_DIR/.worktrees/eng-170" ]

  # The branch was deleted so a re-run can recreate it
  ! git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/eng-170"

  # ralph-failed label was added; verify-after-add gate ran.
  grep -qF "add_label ENG-170 ralph-failed" "$STUB_LINEAR_CALLS_FILE"
  grep -qF "get_labels ENG-170" "$STUB_LINEAR_CALLS_FILE"
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
  local event; event="$(jq -r '.[0].event' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$event" = "end" ]
  local outcome; outcome="$(jq -r '.[0].outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$outcome" = "local_residue" ]
  local residue_branch; residue_branch="$(jq -r '.[0].residue_branch' < "$REPO_DIR/.sensible-ralph/progress.json")"
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
  local event; event="$(jq -r '.[0].event' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$event" = "end" ]
  local outcome; outcome="$(jq -r '.[0].outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$outcome" = "local_residue" ]
  local residue_path; residue_path="$(jq -r '.[0].residue_path' < "$REPO_DIR/.sensible-ralph/progress.json")"
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
  local eng191_outcome; eng191_outcome="$(jq -r '.[] | select(.issue == "ENG-191" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$eng191_outcome" = "local_residue" ]

  # ENG-192 was NOT skipped — taint did not propagate
  local eng192_outcome; eng192_outcome="$(jq -r '.[] | select(.issue == "ENG-192" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$eng192_outcome" != "skipped" ]
}

# ---------------------------------------------------------------------------
# 20c. ENG-279 reuse path — branch+worktree pre-exist (created at /sr-spec
#      step 7); orchestrator reuses, merges in-review parents in, writes
#      post-merge HEAD to .sensible-ralph-base-sha, dispatches.
# ---------------------------------------------------------------------------
@test "reuse path clean merge: existing branch+worktree, in-review parent merged in, base-sha = merge commit" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # In-review parent with content the merge will pull in.
  git -C "$REPO_DIR" checkout -b eng-280-parent -q
  echo "parent content" > "$REPO_DIR/parent.txt"
  git -C "$REPO_DIR" add parent.txt
  git -C "$REPO_DIR" commit -m "parent commit" -q
  git -C "$REPO_DIR" checkout main -q

  # Pre-create the issue's branch+worktree (simulating /sr-spec step 7) with
  # a spec commit so the spec HEAD is identifiable.
  local wt_path="$REPO_DIR/.worktrees/eng-300"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-300" -q
  echo "spec content" > "$wt_path/docs-spec.md"
  git -C "$wt_path" add docs-spec.md
  git -C "$wt_path" commit -m "spec commit" -q
  local spec_head; spec_head="$(git -C "$wt_path" rev-parse HEAD)"

  export STUB_DAG_BASE_ENG_300="eng-280-parent"
  export STUB_CLAUDE_ISSUE_ID="ENG-300"

  local q; q="$(write_queue ENG-300)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # Worktree was reused (still exists, contains both spec + parent content)
  [ -d "$wt_path" ]
  [ -f "$wt_path/docs-spec.md" ]
  [ -f "$wt_path/parent.txt" ]

  # Base-sha = post-merge HEAD = the merge commit (NOT spec_head, NOT parent_head)
  local recorded_sha; recorded_sha="$(cat "$wt_path/.sensible-ralph-base-sha")"
  local post_merge_head; post_merge_head="$(git -C "$wt_path" rev-parse HEAD)"
  [ "$recorded_sha" = "$post_merge_head" ]
  [ "$post_merge_head" != "$spec_head" ]

  # Linear: In Progress was set; claude was dispatched once
  grep -qF "set_state ENG-300 In Progress" "$STUB_LINEAR_CALLS_FILE"
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 1 ]

  # Outcome is in_review (the dispatched session transitioned the state)
  local outcome; outcome="$(jq -r '.[] | select(.issue == "ENG-300" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$outcome" = "in_review" ]
}

# ---------------------------------------------------------------------------
# 20d. ENG-279 reuse path, single-parent conflict — leave-for-agent. Base-sha
#      stays at the pre-merge spec HEAD (MERGING state, no merge commit yet);
#      the agent's conflict-resolution commit is intentionally in scope for
#      prepare-for-review's codex review.
# ---------------------------------------------------------------------------
@test "reuse path single-parent conflict: MERGING state, base-sha = pre-merge spec HEAD, dispatched" {
  # Skip the smart-claude — this session must dispatch even though the
  # worktree is mid-merge (the agent resolves on entry per /sr-implement
  # Step 2). Use a stub that records the call but does NOT transition state
  # (we expect outcome = exit_clean_no_review — that's fine, we just want to
  # observe that dispatch happened and the base-sha is correct).
  export STUB_CLAUDE_EXIT=0

  # Conflicting parent.
  git -C "$REPO_DIR" checkout -b eng-281-parent-conflict -q
  echo "parent version" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "parent conflict" -q
  git -C "$REPO_DIR" checkout main -q

  # Pre-create issue branch+worktree with a conflicting commit.
  local wt_path="$REPO_DIR/.worktrees/eng-301"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-301" -q
  echo "spec version" > "$wt_path/conflict.txt"
  git -C "$wt_path" add conflict.txt
  git -C "$wt_path" commit -m "spec conflict commit" -q
  local spec_head; spec_head="$(git -C "$wt_path" rev-parse HEAD)"

  export STUB_DAG_BASE_ENG_301="eng-281-parent-conflict"
  export STUB_CLAUDE_ISSUE_ID="ENG-301"

  local q; q="$(write_queue ENG-301)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # Worktree is in MERGING state — conflict markers, no merge commit yet.
  [ -d "$wt_path" ]
  run git -C "$wt_path" status --porcelain
  [[ "$output" =~ ^(UU|AA) ]]

  # Base-sha = pre-merge spec HEAD (HEAD has not advanced — single-parent
  # leave-for-agent intentionally captures the spec HEAD so the resolution
  # commit lands in /prepare-for-review's diff).
  local recorded_sha; recorded_sha="$(cat "$wt_path/.sensible-ralph-base-sha")"
  [ "$recorded_sha" = "$spec_head" ]
  local current_head; current_head="$(git -C "$wt_path" rev-parse HEAD)"
  [ "$current_head" = "$spec_head" ]

  # ENG-282: marker file present with one SHA line for the conflicting parent.
  [ -f "$wt_path/.sensible-ralph-pending-merges" ]
  local marker_lines; marker_lines="$(wc -l < "$wt_path/.sensible-ralph-pending-merges" | tr -d ' ')"
  [ "$marker_lines" -eq 1 ]
  local marker_sha; marker_sha="$(awk '{print $1}' "$wt_path/.sensible-ralph-pending-merges")"
  local parent_sha; parent_sha="$(git -C "$REPO_DIR" rev-parse "eng-281-parent-conflict")"
  [ "$marker_sha" = "$parent_sha" ]

  # Linear: In Progress was set; claude was dispatched once
  grep -qF "set_state ENG-301 In Progress" "$STUB_LINEAR_CALLS_FILE"
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 1 ]
}

# ---------------------------------------------------------------------------
# ENG-282: reuse path with TWO conflicting parents. Helper now leaves
# conflicts in place (was: aborts + setup_failed) and writes the
# .sensible-ralph-pending-merges marker. Dispatch proceeds; base-sha = spec
# HEAD (pre-merge). The dispatched session resolves the marker per
# /sr-implement Step 2.
# ---------------------------------------------------------------------------
@test "reuse path multi-parent conflict: MERGING state, marker file written, base-sha = pre-merge spec HEAD, dispatched" {
  export STUB_CLAUDE_EXIT=0

  # Two parents both conflicting with the worktree's spec commit on
  # conflict.txt. The branchpoint (main) does NOT add conflict.txt; both
  # parents add it independently → add/add conflict on each parent merge.
  git -C "$REPO_DIR" checkout -b eng-282-parent-a -q
  echo "parent A" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "parent A" -q
  git -C "$REPO_DIR" checkout main -q

  git -C "$REPO_DIR" checkout -b eng-282-parent-b -q
  echo "parent B" > "$REPO_DIR/parent-b-only.txt"
  git -C "$REPO_DIR" add parent-b-only.txt
  git -C "$REPO_DIR" commit -m "parent B" -q
  git -C "$REPO_DIR" checkout main -q

  local sha_a; sha_a="$(git -C "$REPO_DIR" rev-parse "eng-282-parent-a")"
  local sha_b; sha_b="$(git -C "$REPO_DIR" rev-parse "eng-282-parent-b")"

  # Pre-create issue branch+worktree with a conflicting spec commit.
  local wt_path="$REPO_DIR/.worktrees/eng-302"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-302" -q
  echo "spec version" > "$wt_path/conflict.txt"
  git -C "$wt_path" add conflict.txt
  git -C "$wt_path" commit -m "spec conflict commit" -q
  local spec_head; spec_head="$(git -C "$wt_path" rev-parse HEAD)"

  export STUB_DAG_BASE_ENG_302="INTEGRATION eng-282-parent-a eng-282-parent-b"
  export STUB_CLAUDE_ISSUE_ID="ENG-302"

  local q; q="$(write_queue ENG-302)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # Outcome is NOT setup_failed — the helper now returns 0 with the marker.
  local outcome; outcome="$(jq -r '.[] | select(.issue == "ENG-302" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$outcome" != "setup_failed" ]

  # Worktree is in MERGING state — conflict markers from parent A's merge.
  [ -d "$wt_path" ]
  run git -C "$wt_path" diff --name-only --diff-filter=U
  [ -n "$output" ]

  # Marker file present with both SHAs in original order.
  [ -f "$wt_path/.sensible-ralph-pending-merges" ]
  local marker_lines; marker_lines="$(wc -l < "$wt_path/.sensible-ralph-pending-merges" | tr -d ' ')"
  [ "$marker_lines" -eq 2 ]
  local s1; s1="$(awk 'NR==1 {print $1}' "$wt_path/.sensible-ralph-pending-merges")"
  local s2; s2="$(awk 'NR==2 {print $1}' "$wt_path/.sensible-ralph-pending-merges")"
  [ "$s1" = "$sha_a" ]
  [ "$s2" = "$sha_b" ]

  # Base-sha = pre-merge spec HEAD (HEAD has not advanced).
  local recorded_sha; recorded_sha="$(cat "$wt_path/.sensible-ralph-base-sha")"
  [ "$recorded_sha" = "$spec_head" ]

  # Linear: In Progress was set; claude was dispatched once.
  grep -qF "set_state ENG-302 In Progress" "$STUB_LINEAR_CALLS_FILE"
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 1 ]
}

# ---------------------------------------------------------------------------
# ENG-282: create-path INTEGRATION multi-parent conflict — same shape as
# the reuse-path test above, but with no pre-existing branch+worktree. The
# orchestrator's create branch (worktree_create_with_integration) creates
# the worktree at trunk and merges parents; on conflict it leaves the
# worktree in place with the marker, no setup_failed.
# ---------------------------------------------------------------------------
@test "create path INTEGRATION multi-parent conflict: marker written, dispatched" {
  export STUB_CLAUDE_EXIT=0

  # Parent A conflicts with main on conflict.txt.
  git -C "$REPO_DIR" checkout -b eng-282-cp-a -q
  echo "A version" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "A" -q
  git -C "$REPO_DIR" checkout main -q

  echo "main version" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "main conflict" -q

  # Parent B has unique content; the marker must list both.
  git -C "$REPO_DIR" checkout -b eng-282-cp-b -q
  echo "b-only" > "$REPO_DIR/b-only.txt"
  git -C "$REPO_DIR" add b-only.txt
  git -C "$REPO_DIR" commit -m "B" -q
  git -C "$REPO_DIR" checkout main -q

  local sha_a; sha_a="$(git -C "$REPO_DIR" rev-parse "eng-282-cp-a")"
  local sha_b; sha_b="$(git -C "$REPO_DIR" rev-parse "eng-282-cp-b")"

  export STUB_DAG_BASE_ENG_303="INTEGRATION eng-282-cp-a eng-282-cp-b"
  export STUB_CLAUDE_ISSUE_ID="ENG-303"

  local q; q="$(write_queue ENG-303)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # Outcome is NOT setup_failed.
  local outcome; outcome="$(jq -r '.[] | select(.issue == "ENG-303" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$outcome" != "setup_failed" ]

  local wt_path="$REPO_DIR/.worktrees/eng-303"
  [ -d "$wt_path" ]

  # Worktree in MERGING state with conflict markers.
  run git -C "$wt_path" diff --name-only --diff-filter=U
  [ -n "$output" ]

  # Marker has 2 SHA lines in original order.
  [ -f "$wt_path/.sensible-ralph-pending-merges" ]
  local marker_lines; marker_lines="$(wc -l < "$wt_path/.sensible-ralph-pending-merges" | tr -d ' ')"
  [ "$marker_lines" -eq 2 ]
  local s1; s1="$(awk 'NR==1 {print $1}' "$wt_path/.sensible-ralph-pending-merges")"
  local s2; s2="$(awk 'NR==2 {print $1}' "$wt_path/.sensible-ralph-pending-merges")"
  [ "$s1" = "$sha_a" ]
  [ "$s2" = "$sha_b" ]

  grep -qF "set_state ENG-303 In Progress" "$STUB_LINEAR_CALLS_FILE"
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 20e. ENG-279 partial residue — wrong-branch case (branch exists but the
#      worktree at $path is checked out to a different branch) is treated
#      as local_residue with no Linear mutation, like other partial cases.
# ---------------------------------------------------------------------------
@test "partial residue (wrong-branch): outcome=local_residue, no Linear mutation, no dispatch" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # Issue branch eng-310 exists, but the worktree path is registered to a
  # different branch (operator state we cannot interpret).
  local wt_path="$REPO_DIR/.worktrees/eng-310"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "unrelated-branch" -q
  git -C "$REPO_DIR" branch eng-310

  export STUB_BLOCKERS_ENG_310='[]'

  local q; q="$(write_queue ENG-310)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # claude was NOT invoked
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 0 ]

  # progress.json records local_residue; no Linear mutation
  local outcome; outcome="$(jq -r '.[] | select(.issue == "ENG-310" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$outcome" = "local_residue" ]
  ! grep -q "add_label ENG-310" "$STUB_LINEAR_CALLS_FILE"
  ! grep -q "set_state ENG-310" "$STUB_LINEAR_CALLS_FILE"
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

  # 3 start + 3 end records = 6 total, all with the same run_id
  local records; records="$(jq 'length' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$records" -eq 6 ]

  # Every record carries a non-empty run_id (start records included)
  local null_run_ids; null_run_ids="$(jq '[.[] | select(.run_id == null or .run_id == "")] | length' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$null_run_ids" -eq 0 ]

  # All run_ids are identical within a single run
  local distinct_run_ids; distinct_run_ids="$(jq '[.[].run_id] | unique | length' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$distinct_run_ids" -eq 1 ]

  # run_id matches the ISO 8601 UTC format produced by date -u +%Y-%m-%dT%H:%M:%SZ
  local sample; sample="$(jq -r '.[0].run_id' < "$REPO_DIR/.sensible-ralph/progress.json")"
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

  # Both runs' records are present: each dispatched issue contributes start+end = 4 total
  local records; records="$(jq 'length' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$records" -eq 4 ]

  # Extract each issue's run_id from its end record (start record carries the same id)
  local run_id_210; run_id_210="$(jq -r '.[] | select(.issue == "ENG-210" and .event == "end") | .run_id' < "$REPO_DIR/.sensible-ralph/progress.json")"
  local run_id_211; run_id_211="$(jq -r '.[] | select(.issue == "ENG-211" and .event == "end") | .run_id' < "$REPO_DIR/.sensible-ralph/progress.json")"

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
  [ -f "$REPO_DIR/.sensible-ralph/progress.json" ]
  local leftover_count
  leftover_count="$(find "$REPO_DIR/.sensible-ralph" -maxdepth 1 -name 'progress.json.*' -type f | wc -l | tr -d ' ')"
  [ "$leftover_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 24. .sensible-ralph/progress.json must land under the repo root, not under $PWD.
#     Invoking from a subdirectory or a linked worktree would otherwise bury
#     the audit log in a transient location (linked worktrees are created
#     and removed by ralph itself) and silently discard recovery state.
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

  # .sensible-ralph/progress.json lives under the repo root, not in the invocation subdirectory
  [ -f "$REPO_DIR/.sensible-ralph/progress.json" ]
  [ ! -f "$subdir/.sensible-ralph/progress.json" ]
  # 1 start + 1 end record for a single dispatched issue
  local count; count="$(jq 'length' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# 25. ENG-241 atomic-write invariant: prior progress.json content survives a
#     simulated mid-write abort (a failing jq during _progress_append). The
#     mktemp+jq>tmp+mv pattern relies on `set -e` aborting before `mv` runs
#     when jq fails, so the pre-write progress.json is never overwritten.
#     Verifies this invariant still holds with the new event-discriminated
#     records introduced by ENG-241.
# ---------------------------------------------------------------------------
@test "atomic-write: pre-existing progress.json content survives a failing jq mid-_progress_append" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # Pre-populate progress.json with a valid prior-run record. The orchestrator
  # must not corrupt this when its own jq calls fail.
  mkdir -p "$REPO_DIR/.sensible-ralph"
  local prior='[{"event":"end","issue":"ENG-PRIOR","outcome":"in_review","run_id":"2020-01-01T00:00:00Z"}]'
  printf '%s' "$prior" > "$REPO_DIR/.sensible-ralph/progress.json"

  # Stub jq to ALWAYS fail. The orchestrator will abort early (likely at the
  # first jq call — blocker count, record construction, etc.); the invariant
  # we're verifying is that progress.json is bit-for-bit unchanged after the
  # crash, regardless of where exactly jq broke.
  cat > "$STUB_DIR/jq" <<'JQSH'
#!/usr/bin/env bash
exit 1
JQSH
  chmod +x "$STUB_DIR/jq"

  export STUB_BLOCKERS_ENG_998='[]'
  local q; q="$(write_queue ENG-998)"
  run_orch "$q" || true

  # progress.json content is unchanged
  local current; current="$(cat "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$current" = "$prior" ]

  # No partial tmpfiles linger
  local leftover_count
  leftover_count="$(find "$REPO_DIR/.sensible-ralph" -maxdepth 1 -name 'progress.json.*' -type f | wc -l | tr -d ' ')"
  [ "$leftover_count" -eq 0 ]

  # Restore real jq via the cleanup teardown (rm STUB_DIR removes the stub).
  # The remaining file is parseable by the host's real jq once the stub is
  # gone. Run via `command jq` from outside STUB_DIR's PATH precedence by
  # reaching the real binary directly through `env -i`-style path manipulation.
  local real_jq; real_jq="$(PATH="${PATH#"$STUB_DIR":}" command -v jq)"
  [ -n "$real_jq" ]
  "$real_jq" '.' < "$REPO_DIR/.sensible-ralph/progress.json" > /dev/null
}

# ---------------------------------------------------------------------------
# 26. ENG-322 partial-write coverage. The verify-after-add gate plus the gated
#     state revert at the `failed`/`exit_clean_no_review` branches produce
#     several distinct terminal states depending on which Linear API write
#     succeeded. The four tests below exercise each path against the
#     `failed` branch — `exit_clean_no_review` shares the textually-identical
#     block, so per-branch divergence is not asserted.
#
#     Partial-write row 2: revert fails after a verified label-add. Issue
#     terminates as labeled-In-Progress; criterion 2b operator recipe applies.
# ---------------------------------------------------------------------------
@test "ENG-322 revert fails after verified label-add: get_labels seen, set_state Approved attempted, warning emitted, outcome=failed" {
  export STUB_CLAUDE_EXIT=4

  # Verify will see the label (label-add succeeded, get_labels returns it).
  export STUB_LABELS_ENG_240="ralph-failed"
  # Only the post-dispatch revert call fails; dispatch-time In Progress
  # transition still succeeds (the helper sets STUB_DIR/linear_state_ENG-240).
  export STUB_SET_STATE_FAIL_ON_REVERT_ENG_240=1

  local q; q="$(write_queue ENG-240)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  grep -qF "add_label ENG-240 ralph-failed" "$STUB_LINEAR_CALLS_FILE"
  grep -qF "get_labels ENG-240" "$STUB_LINEAR_CALLS_FILE"
  grep -qF "set_state ENG-240 Approved" "$STUB_LINEAR_CALLS_FILE"

  # Call-site warning, not the helper's internal warnings.
  [[ "$output" == *"failed to revert ENG-240 to Approved"* ]]

  local outcome; outcome="$(jq -r '.[] | select(.issue == "ENG-240" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$outcome" = "failed" ]
}

# Partial-write row 5: linear_add_label hard-fails. Helper short-circuits
# before the verify-read; gate keeps the revert from running.
@test "ENG-322 label-add hard-fails: get_labels NOT seen, no revert, helper warning emitted, outcome=failed" {
  export STUB_CLAUDE_EXIT=5
  export STUB_ADD_LABEL_FAIL_ENG_241=1

  local q; q="$(write_queue ENG-241)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  grep -qF "add_label ENG-241 ralph-failed" "$STUB_LINEAR_CALLS_FILE"
  ! grep -qF "get_labels ENG-241" "$STUB_LINEAR_CALLS_FILE"
  ! grep -qF "set_state ENG-241 Approved" "$STUB_LINEAR_CALLS_FILE"

  [[ "$output" == *"failed to add ralph-failed label to ENG-241; leaving state In Progress (continuing)"* ]]

  local outcome; outcome="$(jq -r '.[] | select(.issue == "ENG-241" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$outcome" = "failed" ]
}

# Partial-write row 4: label-add succeeds but the workspace label name is
# missing, so the post-add read returns empty (Linear silent-no-op). The
# verify gate detects the absence and prevents the state revert.
@test "ENG-322 label silently no-ops: gate detects absence, no revert, helper warning emitted, outcome=failed" {
  export STUB_CLAUDE_EXIT=6
  # Label-add succeeds (no STUB_ADD_LABEL_FAIL_ENG_242), get_labels returns
  # empty (no STUB_LABELS_ENG_242 — the silent-no-op simulator).

  local q; q="$(write_queue ENG-242)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  grep -qF "add_label ENG-242 ralph-failed" "$STUB_LINEAR_CALLS_FILE"
  grep -qF "get_labels ENG-242" "$STUB_LINEAR_CALLS_FILE"
  ! grep -qF "set_state ENG-242 Approved" "$STUB_LINEAR_CALLS_FILE"

  [[ "$output" == *"ralph-failed did not land on ENG-242 after label-add (silent no-op"* ]]

  local outcome; outcome="$(jq -r '.[] | select(.issue == "ENG-242" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$outcome" = "failed" ]
}

# Partial-write row 3: linear_get_issue_labels fails after a successful
# label-add. Helper cannot confirm the label landed — labeled-but-unverified.
# Gate trips conservatively; criterion 2b recipe handles the recovery.
@test "ENG-322 verify-read fails after label-add: gate trips, no revert, helper warning emitted, outcome=failed" {
  export STUB_CLAUDE_EXIT=8
  # Label-add succeeds, but the post-add read fails transiently.
  export STUB_GET_LABELS_FAIL_ENG_243=1

  local q; q="$(write_queue ENG-243)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  grep -qF "add_label ENG-243 ralph-failed" "$STUB_LINEAR_CALLS_FILE"
  grep -qF "get_labels ENG-243" "$STUB_LINEAR_CALLS_FILE"
  ! grep -qF "set_state ENG-243 Approved" "$STUB_LINEAR_CALLS_FILE"

  [[ "$output" == *"linear_get_issue_labels failed for ENG-243 after label-add"* ]]

  local outcome; outcome="$(jq -r '.[] | select(.issue == "ENG-243" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$outcome" = "failed" ]
}

# setup_failed surface: same verify-after-add gate runs, but no state revert
# (state is still Approved because setup_failed paths fire before the
# dispatch-time In Progress transition). Silent no-op surfaces as a stderr
# diagnostic; outcome stays setup_failed.
@test "ENG-322 setup_failed with label silent no-op: get_labels seen, no revert, helper warning emitted, outcome=setup_failed" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"

  # Force dag_base empty for ENG-244 to trigger setup_failed (same trigger as
  # test 12, but for a different issue ID so no cross-test interference).
  export STUB_DAG_BASE_ENG_244="   "
  export STUB_BLOCKERS_ENG_244='[]'
  # Label-add returns success; verify-read returns empty -> silent no-op.

  local q; q="$(write_queue ENG-244)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  grep -qF "add_label ENG-244 ralph-failed" "$STUB_LINEAR_CALLS_FILE"
  grep -qF "get_labels ENG-244" "$STUB_LINEAR_CALLS_FILE"
  # No state revert in setup_failed — state was never moved off Approved.
  ! grep -qF "set_state ENG-244 Approved" "$STUB_LINEAR_CALLS_FILE"

  [[ "$output" == *"ralph-failed did not land on ENG-244 after label-add (silent no-op"* ]]

  local outcome; outcome="$(jq -r '.[] | select(.issue == "ENG-244" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$outcome" = "setup_failed" ]
  local step; step="$(jq -r '.[] | select(.issue == "ENG-244" and .event == "end") | .failed_step' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$step" = "dag_base_empty" ]
}

# ENG-308: session-diagnostics fields (session_id, transcript_path,
# worktree_log_path, hint) on start records and dispatched-outcome end
# records.
# ---------------------------------------------------------------------------

@test "ENG-308 start record carries session_id, transcript_path, worktree_log_path" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"
  export STUB_CLAUDE_ISSUE_ID="ENG-308"

  local q; q="$(write_queue ENG-308)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # session_id present on the start record, lowercase canonical UUID v4.
  local sid; sid="$(jq -r '.[] | select(.issue == "ENG-308" and .event == "start") | .session_id' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [[ "$sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]

  # transcript_path is absolute and contains the slug-encoded worktree path + session id.
  local tp; tp="$(jq -r '.[] | select(.issue == "ENG-308" and .event == "start") | .transcript_path' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [[ "$tp" == /* ]]
  [[ "$tp" == *"/projects/"* ]]
  [[ "$tp" == *"$sid.jsonl" ]]

  # worktree_log_path is the absolute dispatch-time path into the worktree.
  local wlp; wlp="$(jq -r '.[] | select(.issue == "ENG-308" and .event == "start") | .worktree_log_path' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$wlp" = "$REPO_DIR/.worktrees/eng-308/ralph-output.log" ]
}

@test "ENG-308 in_review end record carries the same session_id and path fields" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"
  export STUB_CLAUDE_ISSUE_ID="ENG-308"

  local q; q="$(write_queue ENG-308)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  local start_sid; start_sid="$(jq -r '.[] | select(.issue == "ENG-308" and .event == "start") | .session_id' < "$REPO_DIR/.sensible-ralph/progress.json")"
  local end_sid;   end_sid="$(jq -r '.[] | select(.issue == "ENG-308" and .event == "end") | .session_id' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$start_sid" = "$end_sid" ]

  local end_tp; end_tp="$(jq -r '.[] | select(.issue == "ENG-308" and .event == "end") | .transcript_path' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [[ "$end_tp" == *"$end_sid.jsonl" ]]

  local end_wlp; end_wlp="$(jq -r '.[] | select(.issue == "ENG-308" and .event == "end") | .worktree_log_path' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$end_wlp" = "$REPO_DIR/.worktrees/eng-308/ralph-output.log" ]

  # in_review records do not carry a hint (no diagnostic for green outcomes).
  local end_hint; end_hint="$(jq -r '.[] | select(.issue == "ENG-308" and .event == "end") | .hint // "<absent>"' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$end_hint" = "<absent>" ]
}

@test "ENG-308 failed end record carries hint composed by diagnose_session.sh" {
  export STUB_CLAUDE_EXIT=7
  # No transition state -> hard failure path.

  local q; q="$(write_queue ENG-309)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # Empty branch (no impl commits past base) -> H1 fires; clean tree -> H2 silent.
  local end_hint; end_hint="$(jq -r '.[] | select(.issue == "ENG-309" and .event == "end") | .hint' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$end_hint" = "no implementation commits" ]

  # Diagnostic path fields must be present on the failed end record.
  local end_sid; end_sid="$(jq -r '.[] | select(.issue == "ENG-309" and .event == "end") | .session_id' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [[ "$end_sid" =~ ^[0-9a-f]{8}- ]]
  local end_wlp; end_wlp="$(jq -r '.[] | select(.issue == "ENG-309" and .event == "end") | .worktree_log_path' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$end_wlp" = "$REPO_DIR/.worktrees/eng-309/ralph-output.log" ]
}

@test "ENG-308 exit_clean_no_review end record carries hint" {
  export STUB_CLAUDE_EXIT=0
  # No transition state -> soft failure (exit_clean_no_review).

  local q; q="$(write_queue ENG-310)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  local end_outcome; end_outcome="$(jq -r '.[] | select(.issue == "ENG-310" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$end_outcome" = "exit_clean_no_review" ]

  local end_hint; end_hint="$(jq -r '.[] | select(.issue == "ENG-310" and .event == "end") | .hint' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$end_hint" = "no implementation commits" ]
}

@test "ENG-308 unknown_post_state end record carries session_id, paths, and hint" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"
  export STUB_GET_STATE_FAIL_ENG_311=1

  local q; q="$(write_queue ENG-311)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  local outcome; outcome="$(jq -r '.[] | select(.issue == "ENG-311" and .event == "end") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$outcome" = "unknown_post_state" ]

  # session_id, transcript_path, worktree_log_path are present.
  local end_sid; end_sid="$(jq -r '.[] | select(.issue == "ENG-311" and .event == "end") | .session_id' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [[ "$end_sid" =~ ^[0-9a-f]{8}- ]]
  local end_tp; end_tp="$(jq -r '.[] | select(.issue == "ENG-311" and .event == "end") | .transcript_path' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [[ "$end_tp" == *"$end_sid.jsonl" ]]
  local end_wlp; end_wlp="$(jq -r '.[] | select(.issue == "ENG-311" and .event == "end") | .worktree_log_path' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$end_wlp" = "$REPO_DIR/.worktrees/eng-311/ralph-output.log" ]

  # The diagnose helper still runs for unknown_post_state — clean tree +
  # empty branch -> H1 fires.
  local end_hint; end_hint="$(jq -r '.[] | select(.issue == "ENG-311" and .event == "end") | .hint' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$end_hint" = "no implementation commits" ]
}

@test "ENG-308 setup_failed end record does NOT carry session_id / transcript_path / worktree_log_path / hint" {
  # Force dag_base to whitespace-only output so setup fails before claude is invoked.
  export STUB_DAG_BASE_ENG_312="   "

  local q; q="$(write_queue ENG-312)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  local outcome; outcome="$(jq -r '.[0].outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$outcome" = "setup_failed" ]

  # None of the diagnostic fields appear on a setup_failed record.
  local has_session; has_session="$(jq '.[0] | has("session_id")' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$has_session" = "false" ]
  local has_tp; has_tp="$(jq '.[0] | has("transcript_path")' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$has_tp" = "false" ]
  local has_wlp; has_wlp="$(jq '.[0] | has("worktree_log_path")' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$has_wlp" = "false" ]
  local has_hint; has_hint="$(jq '.[0] | has("hint")' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$has_hint" = "false" ]
}

@test "ENG-308 local_residue end record does NOT carry session_id fields" {
  # Pre-create the branch so dispatch lands as local_residue.
  git -C "$REPO_DIR" branch eng-313

  local q; q="$(write_queue ENG-313)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  local outcome; outcome="$(jq -r '.[0].outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$outcome" = "local_residue" ]

  local has_session; has_session="$(jq '.[0] | has("session_id")' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$has_session" = "false" ]
}

@test "ENG-308 skipped end record does NOT carry session_id fields" {
  export STUB_CLAUDE_EXIT=2
  export STUB_BLOCKERS_ENG_315='[{"id":"ENG-314","state":"Approved","branch":"eng-314"}]'
  export STUB_BLOCKERS_ENG_314='[]'

  local q; q="$(write_queue ENG-314 ENG-315)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # ENG-315 was tainted via ENG-314's failure -> skipped, never dispatched.
  local outcome_315; outcome_315="$(jq -r '.[] | select(.issue == "ENG-315") | .outcome' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$outcome_315" = "skipped" ]

  local has_session; has_session="$(jq -r '.[] | select(.issue == "ENG-315") | has("session_id")' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$has_session" = "false" ]
}

@test "ENG-308 transcript_path honors absolute CLAUDE_CONFIG_DIR override" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"
  export STUB_CLAUDE_ISSUE_ID="ENG-316"

  local config_override; config_override="$(cd "$(mktemp -d)" && pwd -P)"
  CLAUDE_CONFIG_DIR="$config_override" run bash -c "cd '$REPO_DIR' && '$STUB_DIR/scripts/orchestrator.sh' '$(write_queue ENG-316)'"

  [ "$status" -eq 0 ]

  local tp; tp="$(jq -r '.[] | select(.issue == "ENG-316" and .event == "start") | .transcript_path' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [[ "$tp" == "$config_override/projects/"* ]]
  rm -rf "$config_override"
}

@test "ENG-308 transcript_path falls back to \$HOME/.claude when CLAUDE_CONFIG_DIR unset" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"
  export STUB_CLAUDE_ISSUE_ID="ENG-317"

  # Use a controlled HOME so we can assert the fallback path.
  local fake_home; fake_home="$(cd "$(mktemp -d)" && pwd -P)"
  HOME="$fake_home" run bash -c "unset CLAUDE_CONFIG_DIR; cd '$REPO_DIR' && '$STUB_DIR/scripts/orchestrator.sh' '$(write_queue ENG-317)'"

  [ "$status" -eq 0 ]

  local tp; tp="$(jq -r '.[] | select(.issue == "ENG-317" and .event == "start") | .transcript_path' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [[ "$tp" == "$fake_home/.claude/projects/"* ]]
  rm -rf "$fake_home"
}

@test "ENG-308 transcript_path falls back with stderr warning when CLAUDE_CONFIG_DIR is empty" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"
  export STUB_CLAUDE_ISSUE_ID="ENG-318"

  local fake_home; fake_home="$(cd "$(mktemp -d)" && pwd -P)"
  HOME="$fake_home" CLAUDE_CONFIG_DIR="" run bash -c "cd '$REPO_DIR' && '$STUB_DIR/scripts/orchestrator.sh' '$(write_queue ENG-318)'"

  [ "$status" -eq 0 ]

  local tp; tp="$(jq -r '.[] | select(.issue == "ENG-318" and .event == "start") | .transcript_path' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [[ "$tp" == "$fake_home/.claude/projects/"* ]]
  [[ "$output" == *"CLAUDE_CONFIG_DIR is set but empty"* ]]
  rm -rf "$fake_home"
}

@test "ENG-308 transcript_path falls back with stderr warning when CLAUDE_CONFIG_DIR is relative" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"
  export STUB_CLAUDE_ISSUE_ID="ENG-319"

  local fake_home; fake_home="$(cd "$(mktemp -d)" && pwd -P)"
  HOME="$fake_home" CLAUDE_CONFIG_DIR="relative/path" run bash -c "cd '$REPO_DIR' && '$STUB_DIR/scripts/orchestrator.sh' '$(write_queue ENG-319)'"

  [ "$status" -eq 0 ]

  local tp; tp="$(jq -r '.[] | select(.issue == "ENG-319" and .event == "start") | .transcript_path' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [[ "$tp" == "$fake_home/.claude/projects/"* ]]
  [[ "$output" == *"is not absolute"* ]]
  rm -rf "$fake_home"
}

@test "ENG-308 worktree_log_path is dispatch-time path even when STDOUT_LOG_FILENAME is changed afterwards" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"
  export STUB_CLAUDE_ISSUE_ID="ENG-320"

  local q; q="$(write_queue ENG-320)"
  run_orch "$q"
  [ "$status" -eq 0 ]

  local persisted; persisted="$(jq -r '.[] | select(.issue == "ENG-320" and .event == "end") | .worktree_log_path' < "$REPO_DIR/.sensible-ralph/progress.json")"
  # Persisted path uses the dispatch-time STDOUT_LOG_FILENAME (ralph-output.log).
  [ "$persisted" = "$REPO_DIR/.worktrees/eng-320/ralph-output.log" ]

  # Reconfigure between dispatch and inspection — the persisted record must
  # NOT change. The orchestrator never reads it back, but consumers
  # (renderer) read it verbatim, so the field's contents are the contract.
  CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME="renamed.log"
  local persisted_after; persisted_after="$(jq -r '.[] | select(.issue == "ENG-320" and .event == "end") | .worktree_log_path' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$persisted_after" = "$persisted" ]
}

@test "ENG-308 diagnose helper runs even when .sensible-ralph-base-sha is unreadable (passes empty spec_base_sha)" {
  export STUB_CLAUDE_EXIT=7

  # Replace the diagnose helper with a recording stub that captures the
  # invocation. The stub mirrors the real helper's contract: prints nothing
  # (no hint), exits 0.
  cat > "$STUB_DIR/scripts/diagnose_session.sh" <<DIAGSH
#!/usr/bin/env bash
printf 'outcome=%s wt=%s base_sha=%s tp=%s\n' "\$1" "\$2" "\$3" "\$4" > "$STUB_DIR/diagnose_invocation"
exit 0
DIAGSH
  chmod +x "$STUB_DIR/scripts/diagnose_session.sh"

  # Pre-removal hook: replace the orchestrator's base-sha file with an
  # unreadable path. The orchestrator writes .sensible-ralph-base-sha pre-
  # dispatch, then dispatches. Our stub is reading the file post-dispatch.
  # Simulate unreadability by replacing with a directory of the same name
  # AFTER the orchestrator's pre-dispatch write — the cleanest way is a
  # wrapper claude stub that removes the file before exiting.
  cat > "$STUB_DIR/claude" <<CLAUDESH
#!/usr/bin/env bash
issue_id=""
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "--name" ]]; then
    shift
    issue_id="\${1%%:*}"
    break
  fi
  shift
done
# Remove the base-sha file so the orchestrator's [[ -r ... ]] check fails
# at hint-computation time and the helper is invoked with empty spec_base_sha.
issue_lc="\$(printf '%s' "\$issue_id" | tr '[:upper:]' '[:lower:]')"
rm -f "$REPO_DIR/.worktrees/\$issue_lc/.sensible-ralph-base-sha"
exit 7
CLAUDESH
  chmod +x "$STUB_DIR/claude"

  local q; q="$(write_queue ENG-321)"
  run_orch "$q"

  [ "$status" -eq 0 ]
  [ -f "$STUB_DIR/diagnose_invocation" ]
  # base_sha arg is the empty string when .sensible-ralph-base-sha is unreadable.
  grep -qE 'base_sha= ' "$STUB_DIR/diagnose_invocation"
}

# ---------------------------------------------------------------------------
# ENG-337: child claude must inherit unset CLAUDE_CONFIG_DIR when parent had
# it unset, so claude's macOS keychain auth fallback continues to work. The
# orchestrator should still propagate a normalized value when the parent had
# an empty/relative (misconfigured) value, preserving ENG-308's defense
# against transcript_path/JSONL divergence.
# ---------------------------------------------------------------------------

@test "ENG-337 child sees CLAUDE_CONFIG_DIR unset when parent had it unset" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"
  export STUB_CLAUDE_ISSUE_ID="ENG-337A"

  local fake_home; fake_home="$(cd "$(mktemp -d)" && pwd -P)"
  HOME="$fake_home" run bash -c "unset CLAUDE_CONFIG_DIR; cd '$REPO_DIR' && '$STUB_DIR/scripts/orchestrator.sh' '$(write_queue ENG-337A)'"

  [ "$status" -eq 0 ]
  [ -f "$STUB_CLAUDE_ENV_CONFIG_DIR_FILE" ]
  run cat "$STUB_CLAUDE_ENV_CONFIG_DIR_FILE"
  [ "$output" = "unset" ]
  rm -rf "$fake_home"
}

@test "ENG-337 child inherits CLAUDE_CONFIG_DIR when parent had it set to absolute path" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"
  export STUB_CLAUDE_ISSUE_ID="ENG-337B"

  local config_override; config_override="$(cd "$(mktemp -d)" && pwd -P)"
  CLAUDE_CONFIG_DIR="$config_override" run bash -c "cd '$REPO_DIR' && '$STUB_DIR/scripts/orchestrator.sh' '$(write_queue ENG-337B)'"

  [ "$status" -eq 0 ]
  run cat "$STUB_CLAUDE_ENV_CONFIG_DIR_FILE"
  [ "$output" = "set:$config_override" ]
  rm -rf "$config_override"
}

@test "ENG-337 child sees normalized CLAUDE_CONFIG_DIR when parent had it set to empty (defended case)" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"
  export STUB_CLAUDE_ISSUE_ID="ENG-337C"

  local fake_home; fake_home="$(cd "$(mktemp -d)" && pwd -P)"
  HOME="$fake_home" CLAUDE_CONFIG_DIR="" run bash -c "cd '$REPO_DIR' && '$STUB_DIR/scripts/orchestrator.sh' '$(write_queue ENG-337C)'"

  [ "$status" -eq 0 ]
  run cat "$STUB_CLAUDE_ENV_CONFIG_DIR_FILE"
  [ "$output" = "set:$fake_home/.claude" ]
  rm -rf "$fake_home"
}

@test "ENG-337 child sees normalized CLAUDE_CONFIG_DIR when parent had it set to relative path (defended case)" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"
  export STUB_CLAUDE_ISSUE_ID="ENG-337D"

  local fake_home; fake_home="$(cd "$(mktemp -d)" && pwd -P)"
  HOME="$fake_home" CLAUDE_CONFIG_DIR="relative/path" run bash -c "cd '$REPO_DIR' && '$STUB_DIR/scripts/orchestrator.sh' '$(write_queue ENG-337D)'"

  [ "$status" -eq 0 ]
  run cat "$STUB_CLAUDE_ENV_CONFIG_DIR_FILE"
  [ "$output" = "set:$fake_home/.claude" ]
  rm -rf "$fake_home"

# ENG-287: orchestrator commitment-publishes ordered_queue.txt with a run_id
# header before the first progress.json record lands. /sr-status reads the
# header directly, so /sr-start's pre-dispatch and the orchestrator's first
# `start` write can no longer mismatch.
# ---------------------------------------------------------------------------

@test "ENG-287 orchestrator publishes ordered_queue.txt with run_id header before dispatch" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"
  export STUB_CLAUDE_ISSUE_ID="ENG-400"

  local q; q="$(write_queue ENG-400)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # ordered_queue.txt published at the canonical path under the repo root.
  local ord="$REPO_DIR/.sensible-ralph/ordered_queue.txt"
  [ -f "$ord" ]

  # First line is the literal-prefixed run_id header in ISO 8601 UTC.
  local first_line; first_line="$(head -n 1 "$ord")"
  [[ "$first_line" =~ ^\#\ run_id:\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]

  # Remaining lines are the issue IDs from the pending queue, in order.
  local rest; rest="$(tail -n +2 "$ord")"
  [ "$rest" = "ENG-400" ]
}

@test "ENG-287 orchestrator's published header run_id matches every progress.json record's run_id" {
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

  local q; q="$(write_queue ENG-401 ENG-402 ENG-403)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # Parse run_id out of the queue file's header line.
  local ord="$REPO_DIR/.sensible-ralph/ordered_queue.txt"
  local header; header="$(head -n 1 "$ord")"
  local header_run_id="${header#\# run_id: }"
  [ -n "$header_run_id" ]

  # Every progress.json record must carry that exact run_id (byte-equal).
  local distinct; distinct="$(jq -r '[.[].run_id] | unique | .[]' < "$REPO_DIR/.sensible-ralph/progress.json")"
  [ "$distinct" = "$header_run_id" ]
}

@test "ENG-287 ordered_queue.txt publish is atomic — sentinel replaced fully, no tmpfile lingers" {
  export STUB_CLAUDE_EXIT=0
  export STUB_CLAUDE_TRANSITION_STATE="In Review"
  export STUB_CLAUDE_ISSUE_ID="ENG-404"

  # Pre-populate ordered_queue.txt with a sentinel from a prior run.
  mkdir -p "$REPO_DIR/.sensible-ralph"
  printf '# run_id: 2020-01-01T00:00:00Z\nENG-PRIOR\n' > "$REPO_DIR/.sensible-ralph/ordered_queue.txt"

  local q; q="$(write_queue ENG-404)"
  run_orch "$q"

  [ "$status" -eq 0 ]

  # Old content fully replaced — no PRIOR id, no old run_id header survives.
  local ord="$REPO_DIR/.sensible-ralph/ordered_queue.txt"
  ! grep -q "ENG-PRIOR" "$ord"
  ! grep -q "2020-01-01" "$ord"
  grep -q "ENG-404" "$ord"

  # No tempfile siblings remain.
  local leftover_count
  leftover_count="$(find "$REPO_DIR/.sensible-ralph" -maxdepth 1 -name 'ordered_queue.txt.*' -type f | wc -l | tr -d ' ')"
  [ "$leftover_count" -eq 0 ]
}

@test "ENG-287 missing queue_pending.txt: orchestrator errors non-zero, ordered_queue.txt NOT written" {
  # Use a path that does not exist.
  local missing="$STUB_DIR/queue_does_not_exist"

  run_orch "$missing"

  [ "$status" -ne 0 ]
  [[ "$output" == *"queue_pending file does not exist"* ]] || [[ "$output" == *"$missing"* ]]
  # Pre-condition: ordered_queue.txt must NOT be written for a contract violation.
  [ ! -f "$REPO_DIR/.sensible-ralph/ordered_queue.txt" ]
}

@test "ENG-287 empty queue_pending.txt: orchestrator errors non-zero, ordered_queue.txt NOT written" {
  # Empty file (whitespace-only also counts).
  local empty="$STUB_DIR/queue_empty"
  : > "$empty"

  run_orch "$empty"

  [ "$status" -ne 0 ]
  [[ "$output" == *"empty"* ]]
  [ ! -f "$REPO_DIR/.sensible-ralph/ordered_queue.txt" ]

  # claude must NOT have been invoked.
  local invocations; invocations="$(wc -l < "$STUB_CLAUDE_ARGS_FILE" | tr -d ' ')"
  [ "$invocations" -eq 0 ]
}
