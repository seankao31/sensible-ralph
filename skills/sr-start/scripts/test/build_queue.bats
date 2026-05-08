#!/usr/bin/env bats
# Tests for scripts/build_queue.sh
# Mirrors the preflight_scan.bats fixture pattern: stubs lib/linear.sh and
# the `linear` CLI binary, copies build_queue.sh into a temp dir so its
# `source $(dirname "$0")/lib/...` resolves to the stubs.
#
# build_queue.sh's interface (ENG-287): takes an output path as $1 and writes
# issue IDs (no header) to that path via a same-directory tempfile + mv. Exit
# codes: 0 = published a non-empty queue; 1 = construction failed; 2 = empty
# queue, nothing published. Stdout is reserved for warnings only.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
BUILD_QUEUE_SH="$SCRIPT_DIR/build_queue.sh"
TOPOSORT_SH="$SCRIPT_DIR/toposort.sh"

setup() {
  STUB_PLUGIN_ROOT="$(mktemp -d)"
  export STUB_PLUGIN_ROOT
  export CLAUDE_PLUGIN_ROOT="$STUB_PLUGIN_ROOT"

  export SENSIBLE_RALPH_PROJECTS="Agent Config"
  export CLAUDE_PLUGIN_OPTION_APPROVED_STATE="Approved"
  export CLAUDE_PLUGIN_OPTION_REVIEW_STATE="In Review"
  export CLAUDE_PLUGIN_OPTION_DONE_STATE="Done"
  export CLAUDE_PLUGIN_OPTION_FAILED_LABEL="ralph-failed"

  export STUB_APPROVED_IDS=""
  export STUB_PRIORITY_DEFAULT=2

  # Per-test output path. mktemp -u so the file does NOT exist before the
  # script runs — the script must create it (or leave it absent on the empty/
  # failure paths). Tests that exercise the "leaves destination unchanged"
  # contract pre-populate this path with a sentinel.
  OUT_DIR="$(mktemp -d)"
  export OUT_DIR
  OUT_PATH="$OUT_DIR/queue_pending.txt"
  export OUT_PATH

  # Stub plugin root layout: shared libs under lib/, build_queue.sh under
  # skills/sr-start/scripts/.
  mkdir -p "$STUB_PLUGIN_ROOT/lib"
  mkdir -p "$STUB_PLUGIN_ROOT/skills/sr-start/scripts"
  cat > "$STUB_PLUGIN_ROOT/lib/linear.sh" <<'LINEARSH'
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
  cat > "$STUB_PLUGIN_ROOT/linear" <<'STUBLINEAR'
#!/usr/bin/env bash
issue_id=""
for arg in "$@"; do
  [[ "$arg" == ENG-* ]] && { issue_id="$arg"; break; }
done
var_name="STUB_PRIORITY_$(printf '%s' "$issue_id" | tr '-' '_')"
priority="${!var_name:-${STUB_PRIORITY_DEFAULT:-2}}"
printf '{"priority": %s}' "$priority"
STUBLINEAR
  chmod +x "$STUB_PLUGIN_ROOT/linear"
  export PATH="$STUB_PLUGIN_ROOT:$PATH"

  # Marker setup — script's auto-source gate is "<repo-root>|<scope-hash>".
  local _repo_root _scope_hash
  _repo_root="$(git rev-parse --show-toplevel)"
  _scope_hash=""
  if [[ -f "$_repo_root/.sensible-ralph.json" ]]; then
    _scope_hash="$(shasum -a 1 < "$_repo_root/.sensible-ralph.json" | awk '{print $1}')"
  fi
  export SENSIBLE_RALPH_SCOPE_LOADED="$_repo_root|$_scope_hash"

  cp "$BUILD_QUEUE_SH" "$STUB_PLUGIN_ROOT/skills/sr-start/scripts/build_queue.sh"
  cp "$TOPOSORT_SH" "$STUB_PLUGIN_ROOT/skills/sr-start/scripts/toposort.sh"
  cp "$SCRIPT_DIR/../../../lib/defaults.sh" "$STUB_PLUGIN_ROOT/lib/defaults.sh"
}

teardown() {
  rm -rf "$STUB_PLUGIN_ROOT" "$OUT_DIR"
}

# ---------------------------------------------------------------------------
# 1. Single approved issue with no blockers → emitted into the destination
# ---------------------------------------------------------------------------
@test "single approved issue with no blockers is written to destination" {
  export STUB_APPROVED_IDS="ENG-1"
  export STUB_BLOCKERS_ENG_1="[]"

  run bash "$STUB_PLUGIN_ROOT/skills/sr-start/scripts/build_queue.sh" "$OUT_PATH"

  [ "$status" -eq 0 ]
  [ -f "$OUT_PATH" ]
  [ "$(cat "$OUT_PATH")" = "ENG-1" ]
}

# ---------------------------------------------------------------------------
# 2. Approved issue blocked by Approved issue: BOTH emitted in dependency
#    order (parent first). Rule 3b (Decision 6): an Approved blocker that is
#    also in this run's queue counts as resolved at queue-build time because
#    toposort guarantees the parent dispatches first and reaches In Review
#    before the child's turn.
# ---------------------------------------------------------------------------
@test "approved-blocked-by-approved chain emits parent then child" {
  export STUB_APPROVED_IDS="ENG-2
ENG-3"
  export STUB_BLOCKERS_ENG_2="[]"
  export STUB_BLOCKERS_ENG_3='[{"id":"ENG-2","state":"Approved","branch":"eng-2"}]'

  run bash "$STUB_PLUGIN_ROOT/skills/sr-start/scripts/build_queue.sh" "$OUT_PATH"

  [ "$status" -eq 0 ]
  [ -f "$OUT_PATH" ]
  local lines=()
  while IFS= read -r line; do lines+=("$line"); done < "$OUT_PATH"
  [ "${lines[0]}" = "ENG-2" ]
  [ "${lines[1]}" = "ENG-3" ]
}

# ---------------------------------------------------------------------------
# 3. Issue with non-runnable blocker (Todo, etc.) is dropped with a stderr
#    warning. The orchestrator only dispatches Approved issues, so a Todo
#    blocker won't clear overnight and the child can't run this session.
# ---------------------------------------------------------------------------
@test "approved issue with todo blocker is skipped with warning, exits 2" {
  export STUB_APPROVED_IDS="ENG-4"
  export STUB_BLOCKERS_ENG_4='[{"id":"ENG-99","state":"Todo","branch":"eng-99"}]'

  run bash "$STUB_PLUGIN_ROOT/skills/sr-start/scripts/build_queue.sh" "$OUT_PATH"

  # ENG-4 is the only approved issue and it's skipped — nothing left to
  # publish, so this is the empty-queue exit path (2).
  [ "$status" -eq 2 ]
  [ ! -f "$OUT_PATH" ]
  [[ "$output" == *"skipping ENG-4"* ]] || [[ "$output" == *"not pickup-ready"* ]]
}

# ---------------------------------------------------------------------------
# 4. Issue with In Review blocker → emitted (resolved blocker is fine)
# ---------------------------------------------------------------------------
@test "approved issue with in-review blocker is emitted" {
  export STUB_APPROVED_IDS="ENG-5"
  export STUB_BLOCKERS_ENG_5='[{"id":"ENG-50","state":"In Review","branch":"eng-50"}]'

  run bash "$STUB_PLUGIN_ROOT/skills/sr-start/scripts/build_queue.sh" "$OUT_PATH"

  [ "$status" -eq 0 ]
  [ -f "$OUT_PATH" ]
  [ "$(cat "$OUT_PATH")" = "ENG-5" ]
}

# ---------------------------------------------------------------------------
# 5. Approved blocker NOT in this run's queue → child is skipped. Codex P1:
#    a blocker can be Approved but excluded from linear_list_approved_issues
#    (ralph-failed label, in a different project, etc.). Without this check,
#    toposort silently treats the missing blocker as "already done" and the
#    child dispatches against main even though its parent can't clear.
# ---------------------------------------------------------------------------
@test "child whose approved in-scope blocker is not in queue is skipped" {
  # ENG-6 is the only issue in our project's Approved queue.
  # ENG-99 is Approved in-scope (Agent Config) but NOT listed — ralph-failed-labeled.
  export STUB_APPROVED_IDS="ENG-6"
  export STUB_BLOCKERS_ENG_6='[{"id":"ENG-99","state":"Approved","branch":"eng-99","project":"Agent Config"}]'

  run bash "$STUB_PLUGIN_ROOT/skills/sr-start/scripts/build_queue.sh" "$OUT_PATH"

  # ENG-6 skipped → empty queue → exit 2, destination not created.
  [ "$status" -eq 2 ]
  [ ! -f "$OUT_PATH" ]
  if [[ "$output" != *"skipping ENG-6"* ]]; then
    echo "expected 'skipping ENG-6' in output, got: $output" >&2
    return 1
  fi
  if [[ "$output" != *"in scope"* ]]; then
    echo "expected 'in scope' discriminator in output, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 6. A child whose approved blocker is in a project OUTSIDE
#    SENSIBLE_RALPH_PROJECTS is skipped with a distinct out-of-scope message
#    pointing at .sensible-ralph.json.
# ---------------------------------------------------------------------------
@test "child whose approved blocker is out-of-scope is skipped with scope message" {
  # ENG-6 is the only Agent Config issue in the queue. ENG-99 is Approved in
  # "Machine Config" which is NOT in SENSIBLE_RALPH_PROJECTS here ("Agent Config").
  export STUB_APPROVED_IDS="ENG-6"
  export STUB_BLOCKERS_ENG_6='[{"id":"ENG-99","state":"Approved","branch":"eng-99","project":"Machine Config"}]'

  run bash "$STUB_PLUGIN_ROOT/skills/sr-start/scripts/build_queue.sh" "$OUT_PATH"

  [ "$status" -eq 2 ]
  [ ! -f "$OUT_PATH" ]
  if [[ "$output" != *"outside this run's scope"* ]]; then
    echo "expected out-of-scope phrase in output, got: $output" >&2
    return 1
  fi
  if [[ "$output" != *".sensible-ralph.json"* ]]; then
    echo "expected '.sensible-ralph.json' hint in output, got: $output" >&2
    return 1
  fi
  if [[ "$output" != *"Machine Config"* ]]; then
    echo "expected project name 'Machine Config' in output, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 7. Atomicity — failing toposort must not corrupt the destination.
# ---------------------------------------------------------------------------
@test "toposort failure leaves destination file unchanged (atomic publish)" {
  # Sentinel content the script must NOT touch on the failure path.
  printf 'SENTINEL-PRESERVED\n' > "$OUT_PATH"

  # Replace toposort.sh with a stub that always errors out — simulates a
  # cycle-detection or any other construction failure.
  cat > "$STUB_PLUGIN_ROOT/skills/sr-start/scripts/toposort.sh" <<'TOPO'
#!/usr/bin/env bash
echo "stub toposort failure" >&2
exit 1
TOPO
  chmod +x "$STUB_PLUGIN_ROOT/skills/sr-start/scripts/toposort.sh"

  export STUB_APPROVED_IDS="ENG-7"
  export STUB_BLOCKERS_ENG_7="[]"

  run bash "$STUB_PLUGIN_ROOT/skills/sr-start/scripts/build_queue.sh" "$OUT_PATH"

  [ "$status" -eq 1 ]
  # Sentinel content is byte-identical — no overwrite, no partial write.
  [ "$(cat "$OUT_PATH")" = "SENTINEL-PRESERVED" ]

  # No tempfile lingers in the destination directory.
  local leftover_count
  leftover_count="$(find "$OUT_DIR" -maxdepth 1 -name 'queue_pending.txt.*' -type f | wc -l | tr -d ' ')"
  [ "$leftover_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 8. Empty queue (no Approved issues) — exit 2, destination unchanged.
# ---------------------------------------------------------------------------
@test "empty approved set with pre-existing destination: exit 2, file unchanged" {
  printf 'SENTINEL-PRESERVED\n' > "$OUT_PATH"
  export STUB_APPROVED_IDS=""

  run bash "$STUB_PLUGIN_ROOT/skills/sr-start/scripts/build_queue.sh" "$OUT_PATH"

  [ "$status" -eq 2 ]
  [ "$(cat "$OUT_PATH")" = "SENTINEL-PRESERVED" ]
  local leftover_count
  leftover_count="$(find "$OUT_DIR" -maxdepth 1 -name 'queue_pending.txt.*' -type f | wc -l | tr -d ' ')"
  [ "$leftover_count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 9. Empty queue with no prior destination file: exit 2, nothing created.
# ---------------------------------------------------------------------------
@test "empty approved set with no prior destination: exit 2, file not created" {
  export STUB_APPROVED_IDS=""

  run bash "$STUB_PLUGIN_ROOT/skills/sr-start/scripts/build_queue.sh" "$OUT_PATH"

  [ "$status" -eq 2 ]
  [ ! -f "$OUT_PATH" ]
  local leftover_count
  leftover_count="$(find "$OUT_DIR" -maxdepth 1 -name 'queue_pending.txt.*' -type f | wc -l | tr -d ' ')"
  [ "$leftover_count" -eq 0 ]
}
