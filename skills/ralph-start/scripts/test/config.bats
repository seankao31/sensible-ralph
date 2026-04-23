#!/usr/bin/env bats
# Tests for scripts/lib/config.sh
# Sources the config loader and verifies RALPH_* env var exports.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CONFIG_SH="$SCRIPT_DIR/lib/config.sh"
LINEAR_SH="$SCRIPT_DIR/lib/linear.sh"
FIXTURE_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
EXAMPLE_CONFIG="$FIXTURE_DIR/config.example.json"

# ---------------------------------------------------------------------------
# Setup: fake repo root with a .ralph.json. config.sh resolves the repo root
# from the caller's cwd, so tests must cd into this fake root before sourcing.
# ---------------------------------------------------------------------------
setup() {
  TEST_REPO_ROOT="$(mktemp -d)"
  git -C "$TEST_REPO_ROOT" init --quiet
  cat > "$TEST_REPO_ROOT/.ralph.json" <<'EOF'
{
  "projects": ["Agent Config", "Machine Config"]
}
EOF
}

teardown() {
  rm -rf "$TEST_REPO_ROOT"
}

# ---------------------------------------------------------------------------
# Helper: source config.sh in a subshell from within TEST_REPO_ROOT, capture
# all RALPH_* exports. Iterating `compgen -v RALPH_` preserves multi-line
# values (e.g. RALPH_PROJECTS) that `env | grep "^RALPH_"` would truncate —
# env separates entries with \n, so a value containing \n looks like a new
# entry that grep filters out.
# ---------------------------------------------------------------------------
source_config() {
  local config_file="$1"
  bash -c '
    cd "$1"
    source "$2" || exit $?
    source "$3" "$4" || exit $?
    for var in $(compgen -v RALPH_); do
      printf "%s=%s\n" "$var" "${!var}"
    done
  ' _ "$TEST_REPO_ROOT" "$LINEAR_SH" "$CONFIG_SH" "$config_file"
}

# ---------------------------------------------------------------------------
# 1. Valid config + .ralph.json exports all workflow RALPH_* vars
# ---------------------------------------------------------------------------
@test "valid config exports all workflow RALPH_* vars with correct values" {
  run source_config "$EXAMPLE_CONFIG"

  [ "$status" -eq 0 ]
  local expected=(
    "RALPH_APPROVED_STATE=Approved"
    "RALPH_IN_PROGRESS_STATE=In Progress"
    "RALPH_REVIEW_STATE=In Review"
    "RALPH_DONE_STATE=Done"
    "RALPH_FAILED_LABEL=ralph-failed"
    "RALPH_STALE_PARENT_LABEL=stale-parent"
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
  if [[ "$output" == *"RALPH_PROMPT_TEMPLATE="* ]]; then
    echo "RALPH_PROMPT_TEMPLATE should not be exported" >&2
    return 1
  fi

  # RALPH_PROJECT is no longer exported — scope moved to RALPH_PROJECTS
  # sourced from the per-repo .ralph.json (ENG-205).
  if [[ "$output" == *"RALPH_PROJECT="* ]]; then
    echo "RALPH_PROJECT should not be exported (replaced by RALPH_PROJECTS)" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 2. Missing required workflow key → exit 1 with error naming the key
# ---------------------------------------------------------------------------
@test "missing required key exits 1 with key name in error" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local bad_config="$tmpdir/bad_config.json"

  # Omit 'model' key
  cat > "$bad_config" <<'EOF'
{
  "approved_state": "Approved",
  "in_progress_state": "In Progress",
  "review_state": "In Review",
  "done_state": "Done",
  "failed_label": "ralph-failed",
  "stale_parent_label": "stale-parent",
  "worktree_base": ".worktrees",
  "stdout_log_filename": "ralph-output.log"
}
EOF

  run bash -c "cd '$TEST_REPO_ROOT' && source '$LINEAR_SH' && source '$CONFIG_SH' '$bad_config'" 2>&1
  [ "$status" -eq 1 ]
  if [[ "$output" != *"model"* ]]; then
    echo "expected 'model' in error output, got: $output" >&2
    return 1
  fi

  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# 3. Malformed global JSON → exit 1 with "failed to parse"
# ---------------------------------------------------------------------------
@test "malformed global JSON exits 1 with failed to parse in error" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  local bad_json="$tmpdir/bad.json"

  echo "not json" > "$bad_json"

  run bash -c "cd '$TEST_REPO_ROOT' && source '$LINEAR_SH' && source '$CONFIG_SH' '$bad_json'" 2>&1
  [ "$status" -eq 1 ]
  if [[ "$output" != *"failed to parse"* ]]; then
    echo "expected 'failed to parse' in error, got: $output" >&2
    return 1
  fi

  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# 4. config.example.json parses cleanly with the fake .ralph.json in place
# ---------------------------------------------------------------------------
@test "config.example.json parses cleanly with no errors" {
  run source_config "$EXAMPLE_CONFIG"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 5. RALPH_CONFIG_LOADED is a tuple "<global-abs-path>|<repo-root-abs-path>"
#    Entry-point scripts gate auto-source on this marker. The tuple lets them
#    re-source when either the global config path OR the repo root changes
#    (e.g., operator ran another repo's ralph in the same shell).
# ---------------------------------------------------------------------------
@test "RALPH_CONFIG_LOADED is a tuple of global-config-path and repo-root" {
  run source_config "$EXAMPLE_CONFIG"

  [ "$status" -eq 0 ]
  if [[ "$output" != *"RALPH_CONFIG_LOADED="*"|"* ]]; then
    echo "RALPH_CONFIG_LOADED should contain '|', got: $output" >&2
    return 1
  fi
  if [[ "$output" != *"config.example.json"* ]]; then
    echo "tuple should contain global config path, got: $output" >&2
    return 1
  fi
  if [[ "$output" != *"$TEST_REPO_ROOT"* ]]; then
    echo "tuple should contain repo root '$TEST_REPO_ROOT', got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 6. .ralph.json 'projects' list → RALPH_PROJECTS is newline-joined string
# ---------------------------------------------------------------------------
@test ".ralph.json projects list exports RALPH_PROJECTS newline-joined" {
  run source_config "$EXAMPLE_CONFIG"

  [ "$status" -eq 0 ]
  # Extract RALPH_PROJECTS value (env output may contain newline inside the
  # value, so we grep-anchor on the var name and pick up the continuation).
  # env separates entries with newlines; a multi-line RALPH_PROJECTS value
  # spans multiple lines in the output until the next RALPH_* name appears.
  if [[ "$output" != *"RALPH_PROJECTS=Agent Config"* ]]; then
    echo "RALPH_PROJECTS missing first project, got: $output" >&2
    return 1
  fi
  if [[ "$output" != *"Machine Config"* ]]; then
    echo "RALPH_PROJECTS missing second project, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 7. Missing .ralph.json → hard error
# ---------------------------------------------------------------------------
@test "missing .ralph.json exits 1 with helpful error" {
  rm -f "$TEST_REPO_ROOT/.ralph.json"

  run bash -c "cd '$TEST_REPO_ROOT' && source '$LINEAR_SH' && source '$CONFIG_SH' '$EXAMPLE_CONFIG'" 2>&1
  [ "$status" -eq 1 ]
  if [[ "$output" != *".ralph.json"* ]]; then
    echo "expected '.ralph.json' in error, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 8. Empty projects list in .ralph.json → hard error
# ---------------------------------------------------------------------------
@test "empty projects list exits 1 with error" {
  cat > "$TEST_REPO_ROOT/.ralph.json" <<'EOF'
{
  "projects": []
}
EOF

  run bash -c "cd '$TEST_REPO_ROOT' && source '$LINEAR_SH' && source '$CONFIG_SH' '$EXAMPLE_CONFIG'" 2>&1
  [ "$status" -eq 1 ]
  if [[ "$output" != *"empty"* ]] && [[ "$output" != *"projects"* ]]; then
    echo "expected 'empty' or 'projects' in error, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 9. Both projects and initiative set → hard error
# ---------------------------------------------------------------------------
@test "both projects and initiative set exits 1" {
  cat > "$TEST_REPO_ROOT/.ralph.json" <<'EOF'
{
  "projects": ["Agent Config"],
  "initiative": "AI Collaboration Toolkit"
}
EOF

  run bash -c "cd '$TEST_REPO_ROOT' && source '$LINEAR_SH' && source '$CONFIG_SH' '$EXAMPLE_CONFIG'" 2>&1
  [ "$status" -eq 1 ]
  if [[ "$output" != *"both"* ]]; then
    echo "expected 'both' in error (projects + initiative), got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 10. Neither projects nor initiative set → hard error
# ---------------------------------------------------------------------------
@test "neither projects nor initiative exits 1" {
  cat > "$TEST_REPO_ROOT/.ralph.json" <<'EOF'
{}
EOF

  run bash -c "cd '$TEST_REPO_ROOT' && source '$LINEAR_SH' && source '$CONFIG_SH' '$EXAMPLE_CONFIG'" 2>&1
  [ "$status" -eq 1 ]
  if [[ "$output" != *"projects"* ]] && [[ "$output" != *"initiative"* ]]; then
    echo "expected 'projects' or 'initiative' in error, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 11. .ralph.json with `initiative` key → config.sh expands via
#     linear_list_initiative_projects (sourced from lib/linear.sh) and
#     exports the resolved project list as RALPH_PROJECTS.
# ---------------------------------------------------------------------------
@test ".ralph.json initiative expands via linear to RALPH_PROJECTS" {
  cat > "$TEST_REPO_ROOT/.ralph.json" <<'EOF'
{
  "initiative": "AI Collab"
}
EOF

  # Stub `linear` in PATH to return a controlled GraphQL response. The stub
  # returns two projects for any `linear api` call.
  local stub_dir="$TEST_REPO_ROOT/_stub_bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/linear" <<'STUB'
#!/usr/bin/env bash
printf '%s' '{"data":{"initiatives":{"nodes":[{"name":"AI Collab","projects":{"pageInfo":{"hasNextPage":false},"nodes":[{"name":"Agent Config"},{"name":"I Said Yes"}]}}]}}}'
STUB
  chmod +x "$stub_dir/linear"

  run bash -c '
    cd "$1"
    export PATH="$2:$PATH"
    source "$3" || exit $?
    source "$4" "$5" || exit $?
    for var in $(compgen -v RALPH_); do
      printf "%s=%s\n" "$var" "${!var}"
    done
  ' _ "$TEST_REPO_ROOT" "$stub_dir" "$LINEAR_SH" "$CONFIG_SH" "$EXAMPLE_CONFIG"

  [ "$status" -eq 0 ]
  if [[ "$output" != *"Agent Config"* ]]; then
    echo "RALPH_PROJECTS missing Agent Config, got: $output" >&2
    return 1
  fi
  if [[ "$output" != *"I Said Yes"* ]]; then
    echo "RALPH_PROJECTS missing I Said Yes, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 12. Initiative that resolves to zero projects → hard error
# ---------------------------------------------------------------------------
@test "initiative resolving to zero projects exits 1" {
  cat > "$TEST_REPO_ROOT/.ralph.json" <<'EOF'
{
  "initiative": "Empty"
}
EOF

  local stub_dir="$TEST_REPO_ROOT/_stub_bin"
  mkdir -p "$stub_dir"
  # The linear_list_initiative_projects truncation guard depends on pageInfo;
  # an initiative with zero projects still returns a valid initiative node
  # with an empty projects list.
  cat > "$stub_dir/linear" <<'STUB'
#!/usr/bin/env bash
printf '%s' '{"data":{"initiatives":{"nodes":[{"name":"Empty","projects":{"pageInfo":{"hasNextPage":false},"nodes":[]}}]}}}'
STUB
  chmod +x "$stub_dir/linear"

  run bash -c '
    cd "$1"
    export PATH="$2:$PATH"
    source "$3" || exit $?
    source "$4" "$5"
  ' _ "$TEST_REPO_ROOT" "$stub_dir" "$LINEAR_SH" "$CONFIG_SH" "$EXAMPLE_CONFIG" 2>&1

  [ "$status" -ne 0 ]
  if [[ "$output" != *"zero projects"* ]]; then
    echo "expected 'zero projects' in error, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 13. config.sh sources cleanly from zsh.
#     Claude Code's Bash tool dispatches commands through /bin/zsh -c on
#     macOS, so skill-doc snippets that source config.sh trip on bash-only
#     constructs. This test reproduces the failure mode from the ENG-249
#     ticket: zsh-side source must succeed and export RALPH_APPROVED_STATE.
# ---------------------------------------------------------------------------
@test "config.sh sources cleanly from zsh" {
  command -v zsh >/dev/null || skip "zsh not installed"

  run zsh -c "
    cd '$TEST_REPO_ROOT'
    source '$LINEAR_SH' || exit 10
    source '$CONFIG_SH' '$EXAMPLE_CONFIG' || exit 11
    printf 'APPROVED=%s\n' \"\$RALPH_APPROVED_STATE\"
  " 2>&1

  [ "$status" -eq 0 ]
  if [[ "$output" != *"APPROVED=Approved"* ]]; then
    echo "expected APPROVED=Approved, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 14. config.sh fails loudly if linear.sh was not pre-sourced. Guards against
#     callers (e.g. future skill-doc snippets) that forget the order
#     dependency — without the guard, the .ralph.json initiative path would
#     hit a late "command not found" on linear_list_initiative_projects,
#     which is much harder to trace than a load-time error.
# ---------------------------------------------------------------------------
@test "config.sh fails loudly if linear.sh not pre-sourced" {
  run bash -c "cd '$TEST_REPO_ROOT' && source '$CONFIG_SH' '$EXAMPLE_CONFIG'" 2>&1
  [ "$status" -eq 1 ]
  if [[ "$output" != *"linear.sh"* ]]; then
    echo "expected 'linear.sh' in error, got: $output" >&2
    return 1
  fi
}
