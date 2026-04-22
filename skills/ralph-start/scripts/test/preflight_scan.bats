#!/usr/bin/env bats
# Tests for scripts/preflight_scan.sh
# Stubs linear_list_approved_issues and linear_get_issue_blockers via a fake
# lib/linear.sh. Stubs the `linear` binary via PATH for description fetching.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
PREFLIGHT_SH="$SCRIPT_DIR/preflight_scan.sh"

# ---------------------------------------------------------------------------
# Setup: create a temp dir structure that mirrors scripts/, inject stubs
# ---------------------------------------------------------------------------
setup() {
  STUB_DIR="$(mktemp -d)"
  export STUB_DIR

  # env vars that config.sh would export
  export RALPH_PROJECTS="Agent Config"
  export RALPH_APPROVED_STATE="Approved"
  export RALPH_FAILED_LABEL="ralph-failed"
  export RALPH_REVIEW_STATE="In Review"
  export RALPH_DONE_STATE="Done"
  # Touch a dummy config and set the marker to the resolved tuple so the
  # entry script's auto-source gate skips loading.
  local dummy="$STUB_DIR/dummy-config.json"
  touch "$dummy"
  export RALPH_CONFIG="$dummy"
  local _repo_root _scope_hash
  _repo_root="$(git rev-parse --show-toplevel)"
  _scope_hash=""
  if [[ -f "$_repo_root/.ralph.json" ]]; then
    _scope_hash="$(shasum -a 1 < "$_repo_root/.ralph.json" | awk '{print $1}')"
  fi
  export RALPH_CONFIG_LOADED="$(cd "$(dirname "$dummy")" && pwd)/$(basename "$dummy")|$_repo_root|$_scope_hash"

  # Default stub values — override per test
  export STUB_APPROVED_IDS=""       # newline-separated issue IDs
  export STUB_BLOCKERS_JSON="{}"    # map of issue_id -> JSON (bash assoc not portable; use file)
  export STUB_DESC_CHARS="300"      # non-whitespace char count to return for all issues
  # linear_label_exists stub:
  #   STUB_DEFAULT_LABEL_EXISTS — fallback rc for any label name (default 0 = exists)
  #   STUB_LABEL_EXISTS_<name-with-dashes-as-underscores> — per-label rc override
  # Convention: rc 0 = exists, 1 = missing, 2 = query error.
  export STUB_DEFAULT_LABEL_EXISTS="0"

  # Write a fake lib/linear.sh that sources its stubs from env
  mkdir -p "$STUB_DIR/lib"
  cat > "$STUB_DIR/lib/linear.sh" <<'LINEARSH'
# Stub lib/linear.sh for preflight_scan tests.
# Reads STUB_APPROVED_IDS and STUB_BLOCKERS_<ISSUEID> env vars.

linear_list_approved_issues() {
  printf '%s' "$STUB_APPROVED_IDS"
}

linear_get_issue_blockers() {
  local issue_id="$1"
  # Env var name: STUB_BLOCKERS_ENG_10 for issue ENG-10
  local var_name
  var_name="STUB_BLOCKERS_$(printf '%s' "$issue_id" | tr '-' '_')"
  local val="${!var_name:-[]}"
  printf '%s' "$val"
}

linear_label_exists() {
  local name="$1"
  # Per-label override: STUB_LABEL_EXISTS_<name-with-'-'→'_'>
  local safe; safe="$(printf '%s' "$name" | tr '-' '_')"
  local var="STUB_LABEL_EXISTS_${safe}"
  return "${!var:-${STUB_DEFAULT_LABEL_EXISTS:-0}}"
}
LINEARSH

  # Write a stub `linear` binary for description fetching
  # preflight_scan.sh calls: linear issue view <id> --json --no-comments
  # The stub returns JSON whose .description field has STUB_DESC_<ISSUEID>
  # non-whitespace characters (we embed the actual chars).
  cat > "$STUB_DIR/linear" <<'STUBLINEAR'
#!/usr/bin/env bash
# Stub for `linear issue view <id> --json --no-comments`
# Returns JSON with a description padded to STUB_DESC_<ISSUEID> non-ws chars.
issue_id=""
for arg in "$@"; do
  if [[ "$arg" == ENG-* ]]; then
    issue_id="$arg"
    break
  fi
done

var_name="STUB_DESC_$(printf '%s' "$issue_id" | tr '-' '_')"
# Fall back to STUB_DESC_CHARS if per-issue override not set
char_count="${!var_name:-${STUB_DESC_CHARS:-300}}"

# Build a description with exactly $char_count non-whitespace chars
desc="$(printf 'x%.0s' $(seq 1 "$char_count"))"
printf '{"description": "%s"}' "$desc"
STUBLINEAR
  chmod +x "$STUB_DIR/linear"
  export PATH="$STUB_DIR:$PATH"

  # Copy preflight_scan.sh into STUB_DIR so $(dirname "$0")/lib/linear.sh resolves.
  cp "$PREFLIGHT_SH" "$STUB_DIR/preflight_scan.sh"
  # Copy the real preflight_labels.sh — exercising the real helper against the
  # stubbed linear_label_exists above, not a hand-rolled second stub.
  cp "$SCRIPT_DIR/lib/preflight_labels.sh" "$STUB_DIR/lib/preflight_labels.sh"
}

teardown() {
  rm -rf "$STUB_DIR"
}

# ---------------------------------------------------------------------------
# Helper: run preflight_scan.sh from the temp dir
# ---------------------------------------------------------------------------
run_preflight() {
  run bash "$STUB_DIR/preflight_scan.sh"
}

# ---------------------------------------------------------------------------
# 1. All clear — no approved issues → exit 0, output "all clear"
# ---------------------------------------------------------------------------
@test "all clear: no approved issues exits 0 with all-clear message" {
  export STUB_APPROVED_IDS=""

  run_preflight

  [ "$status" -eq 0 ]
  [[ "$output" == *"all clear"* ]]
}

# ---------------------------------------------------------------------------
# 2. All clear — approved issues with clean state and good PRD
# ---------------------------------------------------------------------------
@test "all clear: approved issues with no anomalies exits 0" {
  export STUB_APPROVED_IDS="ENG-1
ENG-2"
  # ENG-1 has no blockers; ENG-2 has a Done blocker
  export STUB_BLOCKERS_ENG_1="[]"
  export STUB_BLOCKERS_ENG_2='[{"id":"ENG-3","state":"Done","branch":"eng-3-done"}]'
  # ENG-3 (blocker of ENG-2) has no blockers of its own
  export STUB_BLOCKERS_ENG_3="[]"
  # Good PRD (300 chars)
  export STUB_DESC_CHARS=300

  run_preflight

  [ "$status" -eq 0 ]
  [[ "$output" == *"all clear"* ]]
}

# ---------------------------------------------------------------------------
# 3. Canceled blocker → exit 1, output contains "canceled" and issue ID
# ---------------------------------------------------------------------------
@test "canceled blocker exits 1 with canceled and issue ID in output" {
  export STUB_APPROVED_IDS="ENG-10"
  export STUB_BLOCKERS_ENG_10='[{"id":"ENG-5","state":"Canceled","branch":"eng-5-foo"}]'
  export STUB_BLOCKERS_ENG_5="[]"
  export STUB_DESC_CHARS=300

  run_preflight

  [ "$status" -eq 1 ]
  [[ "$output" == *"canceled"* ]]
  [[ "$output" == *"ENG-10"* ]]
}

# ---------------------------------------------------------------------------
# 4. Duplicate blocker → exit 1, output contains "duplicate" and issue ID
# ---------------------------------------------------------------------------
@test "duplicate blocker exits 1 with duplicate and issue ID in output" {
  export STUB_APPROVED_IDS="ENG-20"
  export STUB_BLOCKERS_ENG_20='[{"id":"ENG-7","state":"Done","branch":"eng-7"},{"id":"ENG-7","state":"Done","branch":"eng-7"}]'
  export STUB_BLOCKERS_ENG_7="[]"
  export STUB_DESC_CHARS=300

  run_preflight

  [ "$status" -eq 1 ]
  [[ "$output" == *"duplicate"* ]]
  [[ "$output" == *"ENG-20"* ]]
}

# ---------------------------------------------------------------------------
# 4b. Duplicate-state blocker → exit 1, output contains "Duplicate state" and issue ID
# ---------------------------------------------------------------------------
@test "duplicate-state blocker exits 1 with Duplicate state and issue ID in output" {
  export STUB_APPROVED_IDS="ENG-25"
  export STUB_BLOCKERS_ENG_25='[{"id":"ENG-6","state":"Duplicate","branch":"eng-6"}]'
  export STUB_BLOCKERS_ENG_6="[]"
  export STUB_DESC_CHARS=300

  run_preflight

  [ "$status" -eq 1 ]
  [[ "$output" == *"Duplicate state"* ]]
  [[ "$output" == *"ENG-25"* ]]
}

# ---------------------------------------------------------------------------
# 5. Stuck blocker chain → exit 1, output contains "stuck"
# Truly stuck: the chain bottoms out at a non-runnable state (Todo, etc. —
# the orchestrator only picks up Approved issues, so anything other than
# Done/In Review/Approved-with-runnable-blockers will NOT clear overnight).
# ---------------------------------------------------------------------------
@test "stuck blocker chain exits 1 with stuck in output" {
  export STUB_APPROVED_IDS="ENG-30"
  # ENG-30's blocker is ENG-15, which is Approved and in-scope (Agent Config)
  # but not in this run's queue — likely ralph-failed-labeled.
  export STUB_BLOCKERS_ENG_30='[{"id":"ENG-15","state":"Approved","branch":"eng-15","project":"Agent Config"}]'
  # ENG-15's own blocker ENG-9 is in Todo — the orchestrator won't touch it,
  # so the chain genuinely cannot dispatch overnight.
  export STUB_BLOCKERS_ENG_15='[{"id":"ENG-9","state":"Todo","branch":"eng-9","project":"Agent Config"}]'
  export STUB_DESC_CHARS=300

  run_preflight

  [ "$status" -eq 1 ]
  [[ "$output" == *"stuck"* ]]
}

# ---------------------------------------------------------------------------
# 5b. Deep Approved chain that bottoms out at a Done blocker is NOT stuck —
# the chain dispatches overnight in topological order. Codex review: the
# previous one-level-deep stuck-chain check produced false positives here.
# ---------------------------------------------------------------------------
@test "deep approved chain bottoming out at Done is not stuck" {
  # All three Approved nodes must be in the run's queue — otherwise the
  # chain can't actually clear (Approved-but-not-queued is its own anomaly).
  export STUB_APPROVED_IDS="ENG-31
ENG-32
ENG-33"
  # ENG-31 ← ENG-32 (Approved) ← ENG-33 (Approved) ← ENG-34 (Done)
  export STUB_BLOCKERS_ENG_31='[{"id":"ENG-32","state":"Approved","branch":"eng-32"}]'
  export STUB_BLOCKERS_ENG_32='[{"id":"ENG-33","state":"Approved","branch":"eng-33"}]'
  export STUB_BLOCKERS_ENG_33='[{"id":"ENG-34","state":"Done","branch":"eng-34"}]'
  export STUB_DESC_CHARS=300

  run_preflight

  [ "$status" -eq 0 ]
  [[ "$output" == *"all clear"* ]]
}

# ---------------------------------------------------------------------------
# 5d. An Approved blocker that is NOT in this run's approved set (e.g.
# ralph-failed-labeled, or in another project) cannot clear overnight even
# though its state is Approved. Codex P2: previously _chain_runnable trusted
# the state alone and falsely cleared the chain.
# ---------------------------------------------------------------------------
@test "approved blocker not in this run's approved set is reported as stuck" {
  export STUB_APPROVED_IDS="ENG-38"
  # ENG-38 is blocked by ENG-39 (Approved) in Agent Config (in scope), but
  # ENG-39 is NOT in STUB_APPROVED_IDS (excluded by linear_list_approved_issues
  # — e.g. ralph-failed-labeled).
  export STUB_BLOCKERS_ENG_38='[{"id":"ENG-39","state":"Approved","branch":"eng-39","project":"Agent Config"}]'
  # ENG-39 has no own blockers (so it would be "runnable" if it were eligible)
  export STUB_BLOCKERS_ENG_39='[]'
  export STUB_DESC_CHARS=300

  run_preflight

  [ "$status" -eq 1 ]
  [[ "$output" == *"stuck"* ]]
}

# ---------------------------------------------------------------------------
# 5d-2. Approved blocker in a project NOT in RALPH_PROJECTS → out-of-scope
# anomaly. Distinguished from "in-scope but not queueable" because the fix
# is different — the operator adds the project to .ralph.json or resolves
# the relationship.
# ---------------------------------------------------------------------------
@test "approved blocker in out-of-scope project is reported as out-of-scope" {
  export STUB_APPROVED_IDS="ENG-55"
  # ENG-55 is blocked by ENG-56 (Approved) in project "Other", which is NOT
  # in RALPH_PROJECTS (which only has "Agent Config" per setup).
  export STUB_BLOCKERS_ENG_55='[{"id":"ENG-56","state":"Approved","branch":"eng-56","project":"Other"}]'
  export STUB_BLOCKERS_ENG_56='[]'
  export STUB_DESC_CHARS=300

  run_preflight

  [ "$status" -eq 1 ]
  if [[ "$output" != *"out-of-scope"* ]]; then
    echo "expected 'out-of-scope' in output, got: $output" >&2
    return 1
  fi
  if [[ "$output" != *"Other"* ]]; then
    echo "expected project name 'Other' in output, got: $output" >&2
    return 1
  fi
  if [[ "$output" != *".ralph.json"* ]]; then
    echo "expected '.ralph.json' hint in output, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 5c. Cycle in the blocker graph reported as stuck (not infinite loop) —
# recursive stuck-chain check must terminate even if blockers cycle.
# ---------------------------------------------------------------------------
@test "cycle in approved blocker chain is reported as stuck (no infinite loop)" {
  export STUB_APPROVED_IDS="ENG-35"
  # ENG-35 ← ENG-36 ← ENG-37 ← ENG-36 (cycle). All in-scope (Agent Config).
  export STUB_BLOCKERS_ENG_35='[{"id":"ENG-36","state":"Approved","branch":"eng-36","project":"Agent Config"}]'
  export STUB_BLOCKERS_ENG_36='[{"id":"ENG-37","state":"Approved","branch":"eng-37","project":"Agent Config"}]'
  export STUB_BLOCKERS_ENG_37='[{"id":"ENG-36","state":"Approved","branch":"eng-36","project":"Agent Config"}]'
  export STUB_DESC_CHARS=300

  run_preflight

  [ "$status" -eq 1 ]
  [[ "$output" == *"stuck"* ]]
}

# ---------------------------------------------------------------------------
# 6. Trivial PRD (< 200 non-whitespace chars) → exit 1, output contains "PRD" and issue ID
# ---------------------------------------------------------------------------
@test "trivial PRD exits 1 with PRD and issue ID in output" {
  export STUB_APPROVED_IDS="ENG-40"
  export STUB_BLOCKERS_ENG_40="[]"
  export STUB_DESC_ENG_40=50   # only 50 non-ws chars — below threshold

  run_preflight

  [ "$status" -eq 1 ]
  [[ "$output" == *"PRD"* ]]
  [[ "$output" == *"ENG-40"* ]]
}

# ---------------------------------------------------------------------------
# 7. Multiple anomalies in same run → exit 1, all issue IDs in output
# ---------------------------------------------------------------------------
@test "multiple anomalies exits 1 with all anomaly issue IDs in output" {
  export STUB_APPROVED_IDS="ENG-50
ENG-60"
  # ENG-50 has a canceled blocker
  export STUB_BLOCKERS_ENG_50='[{"id":"ENG-8","state":"Canceled","branch":"eng-8"}]'
  export STUB_BLOCKERS_ENG_8="[]"
  # ENG-60 has a trivial PRD
  export STUB_BLOCKERS_ENG_60="[]"
  export STUB_DESC_ENG_50=300
  export STUB_DESC_ENG_60=10

  run_preflight

  [ "$status" -eq 1 ]
  [[ "$output" == *"ENG-50"* ]]
  [[ "$output" == *"ENG-60"* ]]
}

# ---------------------------------------------------------------------------
# 8. Summary line shows anomaly count
# ---------------------------------------------------------------------------
@test "anomaly count summary line is printed when anomalies found" {
  export STUB_APPROVED_IDS="ENG-70"
  export STUB_BLOCKERS_ENG_70='[{"id":"ENG-11","state":"Canceled","branch":"eng-11"}]'
  export STUB_BLOCKERS_ENG_11="[]"
  export STUB_DESC_CHARS=300

  run_preflight

  [ "$status" -eq 1 ]
  [[ "$output" == *"anomaly"* ]]
}

# ---------------------------------------------------------------------------
# 9. Exactly 200 non-whitespace chars → NOT a PRD anomaly (boundary)
# ---------------------------------------------------------------------------
@test "exactly 200 non-whitespace chars is not a PRD anomaly" {
  export STUB_APPROVED_IDS="ENG-80"
  export STUB_BLOCKERS_ENG_80="[]"
  export STUB_DESC_ENG_80=200

  run_preflight

  [ "$status" -eq 0 ]
  [[ "$output" == *"all clear"* ]]
}

# ---------------------------------------------------------------------------
# 10. 199 non-whitespace chars IS a PRD anomaly (boundary)
# ---------------------------------------------------------------------------
@test "199 non-whitespace chars is a PRD anomaly" {
  export STUB_APPROVED_IDS="ENG-81"
  export STUB_BLOCKERS_ENG_81="[]"
  export STUB_DESC_ENG_81=199

  run_preflight

  [ "$status" -eq 1 ]
  [[ "$output" == *"PRD"* ]]
}

# ---------------------------------------------------------------------------
# 11. Stuck chain: blocker is Approved but ALL its own blockers are In Review/Done
#     → NOT stuck (will dispatch overnight)
# ---------------------------------------------------------------------------
@test "approved blocker whose own blockers are all In Review is not stuck" {
  # Both ENG-90 and the Approved blocker ENG-45 must be in this run's queue;
  # an Approved-but-not-queued blocker is itself stuck regardless of its chain.
  export STUB_APPROVED_IDS="ENG-90
ENG-45"
  # ENG-90's blocker is ENG-45, which is Approved
  export STUB_BLOCKERS_ENG_90='[{"id":"ENG-45","state":"Approved","branch":"eng-45"}]'
  # ENG-45's own blockers are all In Review — so NOT stuck
  export STUB_BLOCKERS_ENG_45='[{"id":"ENG-44","state":"In Review","branch":"eng-44"}]'
  export STUB_DESC_CHARS=300

  run_preflight

  [ "$status" -eq 0 ]
  [[ "$output" == *"all clear"* ]]
}

# ---------------------------------------------------------------------------
# 12. Stuck chain: blocker is Approved with ZERO own blockers
#     → NOT stuck (will dispatch on next run — it has no blockers holding it back)
# ---------------------------------------------------------------------------
@test "approved blocker with zero own blockers is not a stuck-chain anomaly" {
  # ENG-Q must be in the run's queue (otherwise Approved-but-not-queued).
  export STUB_APPROVED_IDS="ENG-Z
ENG-Q"
  # ENG-Z's blocker is ENG-Q, which is Approved but has no blockers of its own
  export STUB_BLOCKERS_ENG_Z='[{"id":"ENG-Q","state":"Approved","branch":"eng-q"}]'
  export STUB_BLOCKERS_ENG_Q='[]'
  export STUB_DESC_CHARS=300

  run_preflight

  [ "$status" -eq 0 ]
  [[ "$output" == *"all clear"* ]]
}

# ---------------------------------------------------------------------------
# 13. Missing workspace label: the label named in $RALPH_FAILED_LABEL is not
#     present in Linear. Preflight must fail loud BEFORE any per-issue work.
#     The operator-facing message names both the literal label AND the config
#     var, so operators with non-default configs can tell WHICH config key
#     pointed at the missing label.
# ---------------------------------------------------------------------------
@test "missing failed_label exits non-zero with setup hint, skipping per-issue checks" {
  export STUB_LABEL_EXISTS_ralph_failed=1   # linear_label_exists returns 1 (not found)
  # Seed an issue that WOULD trigger a per-issue anomaly. If the label-existence
  # check does not short-circuit, we'd also see "canceled" in the output.
  export STUB_APPROVED_IDS="ENG-500"
  export STUB_BLOCKERS_ENG_500='[{"id":"ENG-501","state":"Canceled","branch":"eng-501"}]'

  run_preflight

  [ "$status" -ne 0 ]
  [[ "$output" == *"ralph-failed"* ]]
  [[ "$output" == *"RALPH_FAILED_LABEL"* ]]   # message names the config var
  [[ "$output" == *"does not exist"* ]]
  # Short-circuit assertion: per-issue scan must not have run.
  [[ "$output" != *"ENG-500"* ]]
}

# ---------------------------------------------------------------------------
# 14. Label query error: the label existence check itself failed (transient
#     Linear outage, auth error). Surface as a distinct message so the operator
#     can tell "label missing" from "we don't know yet".
# ---------------------------------------------------------------------------
@test "label query error exits non-zero with query-failure hint" {
  export STUB_LABEL_EXISTS_ralph_failed=2   # linear_label_exists returns 2 (query error)
  export STUB_APPROVED_IDS=""

  run_preflight

  [ "$status" -ne 0 ]
  [[ "$output" == *"ralph-failed"* ]]
  [[ "$output" == *"query"* ]]
}

# ---------------------------------------------------------------------------
# 15. Stale-parent label is configured and missing.
#     $RALPH_STALE_PARENT_LABEL is exported (ENG-208 plumbing), the label is
#     missing, and $RALPH_FAILED_LABEL exists. Preflight must report the
#     stale-parent entry specifically and name its config var in the message.
# ---------------------------------------------------------------------------
@test "missing stale_parent_label is reported alongside ralph-failed check" {
  export RALPH_STALE_PARENT_LABEL="stale-parent"
  export STUB_LABEL_EXISTS_stale_parent=1   # stale-parent missing
  # ralph-failed exists (default STUB_DEFAULT_LABEL_EXISTS=0)
  export STUB_APPROVED_IDS=""

  run_preflight

  [ "$status" -ne 0 ]
  [[ "$output" == *"stale-parent"* ]]
  [[ "$output" == *"RALPH_STALE_PARENT_LABEL"* ]]
  [[ "$output" == *"does not exist"* ]]
}

# ---------------------------------------------------------------------------
# 16. $RALPH_STALE_PARENT_LABEL is UNSET (ENG-208 not yet landed on this
#     deploy). The helper must skip that slot silently and NOT fail preflight
#     — unset means "not configured for this workspace", not "missing prereq".
# ---------------------------------------------------------------------------
@test "unset stale_parent_label is skipped silently" {
  unset RALPH_STALE_PARENT_LABEL
  export STUB_APPROVED_IDS=""

  run_preflight

  [ "$status" -eq 0 ]
  [[ "$output" == *"all clear"* ]]
  [[ "$output" != *"stale-parent"* ]]
  [[ "$output" != *"RALPH_STALE_PARENT_LABEL"* ]]
}
