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
  export RALPH_PROJECT="Agent Config"
  export RALPH_APPROVED_STATE="Approved"
  export RALPH_FAILED_LABEL="ralph-failed"
  export RALPH_REVIEW_STATE="In Review"

  # Default stub values — override per test
  export STUB_APPROVED_IDS=""       # newline-separated issue IDs
  export STUB_BLOCKERS_JSON="{}"    # map of issue_id -> JSON (bash assoc not portable; use file)
  export STUB_DESC_CHARS="300"      # non-whitespace char count to return for all issues

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

  # Copy preflight_scan.sh into STUB_DIR so $(dirname "$0")/lib/linear.sh resolves
  cp "$PREFLIGHT_SH" "$STUB_DIR/preflight_scan.sh"
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
# 5. Stuck blocker chain → exit 1, output contains "stuck"
# A blocker is Approved but its own blockers are not all In Review/Done
# ---------------------------------------------------------------------------
@test "stuck blocker chain exits 1 with stuck in output" {
  export STUB_APPROVED_IDS="ENG-30"
  # ENG-30's blocker is ENG-15, which is Approved (not yet In Review/Done)
  export STUB_BLOCKERS_ENG_30='[{"id":"ENG-15","state":"Approved","branch":"eng-15"}]'
  # ENG-15's own blocker ENG-9 is also Approved — so the chain is stuck
  export STUB_BLOCKERS_ENG_15='[{"id":"ENG-9","state":"Approved","branch":"eng-9"}]'
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
  export STUB_APPROVED_IDS="ENG-90"
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
  export STUB_APPROVED_IDS="ENG-Z"
  # ENG-Z's blocker is ENG-Q, which is Approved but has no blockers of its own
  export STUB_BLOCKERS_ENG_Z='[{"id":"ENG-Q","state":"Approved","branch":"eng-q"}]'
  export STUB_BLOCKERS_ENG_Q='[]'
  export STUB_DESC_CHARS=300

  run_preflight

  [ "$status" -eq 0 ]
  [[ "$output" == *"all clear"* ]]
}
