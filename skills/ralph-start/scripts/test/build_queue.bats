#!/usr/bin/env bats
# Tests for scripts/build_queue.sh
# Mirrors the preflight_scan.bats fixture pattern: stubs lib/linear.sh and
# the `linear` CLI binary, copies build_queue.sh into a temp dir so its
# `source $(dirname "$0")/lib/...` resolves to the stubs.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
BUILD_QUEUE_SH="$SCRIPT_DIR/build_queue.sh"
TOPOSORT_SH="$SCRIPT_DIR/toposort.sh"

setup() {
  STUB_DIR="$(mktemp -d)"
  export STUB_DIR

  export RALPH_PROJECT="Agent Config"
  export RALPH_APPROVED_STATE="Approved"
  export RALPH_REVIEW_STATE="In Review"
  export RALPH_DONE_STATE="Done"
  export RALPH_FAILED_LABEL="ralph-failed"

  export STUB_APPROVED_IDS=""
  export STUB_PRIORITY_DEFAULT=2

  mkdir -p "$STUB_DIR/lib"
  cat > "$STUB_DIR/lib/linear.sh" <<'LINEARSH'
linear_list_approved_issues() {
  printf '%s' "$STUB_APPROVED_IDS"
}

linear_get_issue_blockers() {
  local issue_id="$1"
  local var_name="STUB_BLOCKERS_$(printf '%s' "$issue_id" | tr '-' '_')"
  printf '%s' "${!var_name:-[]}"
}
LINEARSH

  # Stub `linear` for the priority lookup (build_queue calls
  # `linear issue view <id> --json --no-comments | jq -r '.priority'`).
  cat > "$STUB_DIR/linear" <<'STUBLINEAR'
#!/usr/bin/env bash
issue_id=""
for arg in "$@"; do
  [[ "$arg" == ENG-* ]] && { issue_id="$arg"; break; }
done
var_name="STUB_PRIORITY_$(printf '%s' "$issue_id" | tr '-' '_')"
priority="${!var_name:-${STUB_PRIORITY_DEFAULT:-2}}"
printf '{"priority": %s}' "$priority"
STUBLINEAR
  chmod +x "$STUB_DIR/linear"
  export PATH="$STUB_DIR:$PATH"

  # Marker setup (script's auto-source gate)
  local dummy="$STUB_DIR/dummy-config.json"
  touch "$dummy"
  export RALPH_CONFIG="$dummy"
  export RALPH_CONFIG_LOADED="$(cd "$(dirname "$dummy")" && pwd)/$(basename "$dummy")"

  cp "$BUILD_QUEUE_SH" "$STUB_DIR/build_queue.sh"
  cp "$TOPOSORT_SH" "$STUB_DIR/toposort.sh"
}

teardown() {
  rm -rf "$STUB_DIR"
}

# ---------------------------------------------------------------------------
# 1. Empty input → empty output, exit 0
# ---------------------------------------------------------------------------
@test "no approved issues outputs nothing and exits 0" {
  export STUB_APPROVED_IDS=""

  run bash "$STUB_DIR/build_queue.sh"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 2. Single approved issue with no blockers → emitted
# ---------------------------------------------------------------------------
@test "single approved issue with no blockers is emitted" {
  export STUB_APPROVED_IDS="ENG-1"
  export STUB_BLOCKERS_ENG_1="[]"

  run bash "$STUB_DIR/build_queue.sh"

  [ "$status" -eq 0 ]
  [ "$output" = "ENG-1" ]
}

# ---------------------------------------------------------------------------
# 3. Approved issue blocked by Approved issue: BOTH emitted in dependency
#    order (parent first). Codex P1: previously the child was silently
#    dropped because the pickup-ready check only accepted Done/In Review
#    blockers, but the rest of the orchestrator stack treats Approved chains
#    as runnable in one overnight session (preflight stuck-chain logic).
# ---------------------------------------------------------------------------
@test "approved-blocked-by-approved chain emits parent then child" {
  export STUB_APPROVED_IDS="ENG-2
ENG-3"
  export STUB_BLOCKERS_ENG_2="[]"
  export STUB_BLOCKERS_ENG_3='[{"id":"ENG-2","state":"Approved","branch":"eng-2"}]'

  run bash "$STUB_DIR/build_queue.sh"

  [ "$status" -eq 0 ]
  # Both must be emitted; parent (ENG-2) before child (ENG-3)
  [[ "$output" == *"ENG-2"* ]]
  [[ "$output" == *"ENG-3"* ]]
  local lines=()
  while IFS= read -r line; do lines+=("$line"); done <<< "$output"
  [ "${lines[0]}" = "ENG-2" ]
  [ "${lines[1]}" = "ENG-3" ]
}

# ---------------------------------------------------------------------------
# 4. Issue with non-runnable blocker (Todo, etc.) is dropped with a stderr
#    warning. The orchestrator only dispatches Approved issues, so a Todo
#    blocker won't clear overnight and the child can't run this session.
# ---------------------------------------------------------------------------
@test "approved issue with todo blocker is skipped with warning" {
  export STUB_APPROVED_IDS="ENG-4"
  export STUB_BLOCKERS_ENG_4='[{"id":"ENG-99","state":"Todo","branch":"eng-99"}]'

  run bash "$STUB_DIR/build_queue.sh"

  [ "$status" -eq 0 ]
  ! [[ "$output" == *"ENG-4"* ]]
  [[ "$output" == *"skipping ENG-4"* ]] || [[ "$output" == *"not pickup-ready"* ]]
}

# ---------------------------------------------------------------------------
# 5. Issue with In Review blocker → emitted (resolved blocker is fine)
# ---------------------------------------------------------------------------
@test "approved issue with in-review blocker is emitted" {
  export STUB_APPROVED_IDS="ENG-5"
  export STUB_BLOCKERS_ENG_5='[{"id":"ENG-50","state":"In Review","branch":"eng-50"}]'

  run bash "$STUB_DIR/build_queue.sh"

  [ "$status" -eq 0 ]
  [ "$output" = "ENG-5" ]
}

# ---------------------------------------------------------------------------
# 6. Approved blocker NOT in this run's queue → child is skipped. Codex P1:
#    a blocker can be Approved but excluded from linear_list_approved_issues
#    (ralph-failed label, in a different project, etc.). Without this check,
#    toposort silently treats the missing blocker as "already done" and the
#    child dispatches against main even though its parent can't clear.
# ---------------------------------------------------------------------------
@test "child whose approved blocker is not in this run's approved set is skipped" {
  # ENG-6 is the only issue in our project's Approved queue.
  # ENG-99 is Approved but NOT listed (e.g. ralph-failed-labeled or in another project).
  export STUB_APPROVED_IDS="ENG-6"
  export STUB_BLOCKERS_ENG_6='[{"id":"ENG-99","state":"Approved","branch":"eng-99"}]'

  run bash "$STUB_DIR/build_queue.sh"

  [ "$status" -eq 0 ]
  ! [[ "$output" == *"ENG-6"* ]]
  [[ "$output" == *"skipping ENG-6"* ]] || [[ "$output" == *"not in this run"* ]] || [[ "$output" == *"not pickup-ready"* ]]
}
