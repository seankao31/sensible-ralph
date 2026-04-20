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

  # Capture RALPH_PROMPT_TEMPLATE directly to verify multi-line value is intact
  prompt="$(bash -c 'source "$1" "$2" && printf "%s" "$RALPH_PROMPT_TEMPLATE"' _ "$CONFIG_SH" "$EXAMPLE_CONFIG")"
  [[ "$prompt" == *"prepare-for-review"* ]]
}

# ---------------------------------------------------------------------------
# 2. Missing required key → exit 1 with error message naming the key
# ---------------------------------------------------------------------------
@test "missing required key exits 1 with key name in error" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local bad_config="$tmpdir/bad_config.json"

  # Write a config that omits the 'model' key
  cat > "$bad_config" <<'EOF'
{
  "project": "Agent Config",
  "approved_state": "Approved",
  "review_state": "In Review",
  "failed_label": "ralph-failed",
  "worktree_base": ".worktrees",
  "stdout_log_filename": "ralph-output.log",
  "prompt_template": "some prompt"
}
EOF

  run bash -c "source '$CONFIG_SH' '$bad_config'" 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"model"* ]]

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
@test "config.sh exports RALPH_CONFIG_LOADED=1 after successful load" {
  run source_config "$EXAMPLE_CONFIG"

  [ "$status" -eq 0 ]
  [[ "$output" == *"RALPH_CONFIG_LOADED=1"* ]]
}
