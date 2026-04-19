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
  bash -c "source '$CONFIG_SH' '$config_file' && env | grep '^RALPH_'"
}

# ---------------------------------------------------------------------------
# 1. All RALPH_* vars are exported with correct values for a valid config
# ---------------------------------------------------------------------------
@test "valid config exports all RALPH_* vars with correct values" {
  run source_config "$EXAMPLE_CONFIG"

  [ "$status" -eq 0 ]
  [[ "$output" == *"RALPH_PROJECT=Agent Config"* ]]
  [[ "$output" == *"RALPH_APPROVED_STATE=Approved"* ]]
  [[ "$output" == *"RALPH_REVIEW_STATE=In Review"* ]]
  [[ "$output" == *"RALPH_FAILED_LABEL=ralph-failed"* ]]
  [[ "$output" == *"RALPH_WORKTREE_BASE=.worktrees"* ]]
  [[ "$output" == *"RALPH_MODEL=opus"* ]]
  [[ "$output" == *"RALPH_STDOUT_LOG=ralph-output.log"* ]]
  # prompt_template is a multi-line string; just check the var is set
  [[ "$output" == *"RALPH_PROMPT_TEMPLATE="* ]]
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
# 3. config.example.json itself parses cleanly — all keys present, no exit
# ---------------------------------------------------------------------------
@test "config.example.json parses cleanly with no errors" {
  run source_config "$EXAMPLE_CONFIG"
  [ "$status" -eq 0 ]
}
