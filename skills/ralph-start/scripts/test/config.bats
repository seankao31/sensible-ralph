#!/usr/bin/env bats
# Tests for scripts/lib/config.sh
# Sources the config loader and verifies RALPH_* env var exports.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CONFIG_SH="$SCRIPT_DIR/lib/config.sh"
FIXTURE_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
EXAMPLE_CONFIG="$FIXTURE_DIR/config.example.json"

# ---------------------------------------------------------------------------
# Helper: source config.sh in a subshell, capture all RALPH_* exports
# ---------------------------------------------------------------------------
source_config() {
  local config_file="$1"
  # Source in a subshell so we can capture exports without polluting the test env
  bash -c 'source "$1" "$2" && env | grep "^RALPH_"' _ "$CONFIG_SH" "$config_file"
}

# ---------------------------------------------------------------------------
# 1. All RALPH_* vars are exported with correct values for a valid config
# ---------------------------------------------------------------------------
@test "valid config exports all RALPH_* vars with correct values" {
  run source_config "$EXAMPLE_CONFIG"

  [ "$status" -eq 0 ]
  # bats only fails the test on the LAST command's exit status, so a series
  # of bare [[ ]] assertions silently passes if only the final one is true.
  # Loop with explicit `return 1` to make every assertion count.
  local expected=(
    "RALPH_PROJECT=Agent Config"
    "RALPH_APPROVED_STATE=Approved"
    "RALPH_IN_PROGRESS_STATE=In Progress"
    "RALPH_REVIEW_STATE=In Review"
    "RALPH_DONE_STATE=Done"
    "RALPH_FAILED_LABEL=ralph-failed"
    "RALPH_WORKTREE_BASE=.worktrees"
    "RALPH_MODEL=opus"
    "RALPH_STDOUT_LOG=ralph-output.log"
  )
  local needle
  for needle in "${expected[@]}"; do
    if [[ "$output" != *"$needle"* ]]; then
      echo "missing expected env export: $needle" >&2
      return 1
    fi
  done

  # RALPH_PROMPT_TEMPLATE is no longer exported — the workflow lives in the
  # ralph-implement skill (ENG-206).
  [[ "$output" != *"RALPH_PROMPT_TEMPLATE="* ]]
}

# ---------------------------------------------------------------------------
# 2. Missing required key → exit 1 with error message naming the key
# ---------------------------------------------------------------------------
@test "missing required key exits 1 with key name in error" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local bad_config="$tmpdir/bad_config.json"

  # Write a config that omits only the 'model' key
  cat > "$bad_config" <<'EOF'
{
  "project": "Agent Config",
  "approved_state": "Approved",
  "in_progress_state": "In Progress",
  "review_state": "In Review",
  "done_state": "Done",
  "failed_label": "ralph-failed",
  "worktree_base": ".worktrees",
  "stdout_log_filename": "ralph-output.log"
}
EOF

  run bash -c "source '$CONFIG_SH' '$bad_config'" 2>&1
  [ "$status" -eq 1 ]
  if [[ "$output" != *"model"* ]]; then
    echo "expected 'model' in error output, got: $output" >&2
    return 1
  fi

  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# 3. Malformed JSON → exit 1 with "failed to parse" in error output
# ---------------------------------------------------------------------------
@test "malformed JSON exits 1 with failed to parse in error" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local bad_json="$tmpdir/bad.json"

  echo "not json" > "$bad_json"

  run bash -c "source '$CONFIG_SH' '$bad_json'" 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to parse"* ]]

  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# 4. config.example.json itself parses cleanly — all keys present, no exit
# ---------------------------------------------------------------------------
@test "config.example.json parses cleanly with no errors" {
  run source_config "$EXAMPLE_CONFIG"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 5. config.sh exports RALPH_CONFIG_LOADED=1 as a dedicated load marker.
#    Entry-point scripts gate auto-source on this marker — using a single
#    RALPH_* var (e.g. RALPH_PROJECT) as the gate would let a shell with a
#    stale partial export skip the auto-source and then trip on missing
#    new vars under set -u. The marker proves config.sh ran to completion.
# ---------------------------------------------------------------------------
@test "config.sh exports RALPH_CONFIG_LOADED with the resolved config path" {
  # Marker carries the resolved config path so a stale marker from another
  # repo's session can't suppress loading the current repo's config (codex P2).
  # The path lets entry-point scripts compare against the expected config and
  # re-source if the location differs.
  run source_config "$EXAMPLE_CONFIG"

  [ "$status" -eq 0 ]
  [[ "$output" == *"RALPH_CONFIG_LOADED="* ]]
  [[ "$output" == *"config.example.json"* ]]
  # Plain "=1" is no longer the marker — must be the path.
  ! [[ "$output" == *"RALPH_CONFIG_LOADED=1"$'\n'* ]]
}
