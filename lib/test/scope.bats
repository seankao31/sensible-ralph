#!/usr/bin/env bats
# Tests for scripts/lib/scope.sh
# Sources the scope loader and verifies RALPH_PROJECTS / RALPH_SCOPE_LOADED.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
# No /lib/ prefix: SCRIPT_DIR resolves to lib/ (parent of lib/test/), and the
# target scripts live directly there — not under lib/lib/.
SCOPE_SH="$SCRIPT_DIR/scope.sh"
LINEAR_SH="$SCRIPT_DIR/linear.sh"

# ---------------------------------------------------------------------------
# Setup: fake repo root with a .ralph.json. scope.sh resolves the repo root
# from the caller's cwd, so tests must cd into this fake root before sourcing.
# ---------------------------------------------------------------------------
setup() {
  TEST_REPO_ROOT="$(mktemp -d)"
  git -C "$TEST_REPO_ROOT" init --quiet
  cat > "$TEST_REPO_ROOT/.ralph.json" <<'EOF'
{
  "projects": ["Project A", "Project B"]
}
EOF
}

teardown() {
  rm -rf "$TEST_REPO_ROOT"
}

# ---------------------------------------------------------------------------
# Helper: source scope.sh in a subshell from within TEST_REPO_ROOT, capture
# all RALPH_* exports. Iterating `compgen -v RALPH_` preserves multi-line
# values (e.g. RALPH_PROJECTS) that `env | grep "^RALPH_"` would truncate —
# env separates entries with \n, so a value containing \n looks like a new
# entry that grep filters out.
# ---------------------------------------------------------------------------
source_scope() {
  bash -c '
    cd "$1"
    source "$2" || exit $?
    source "$3" || exit $?
    for var in $(compgen -v RALPH_); do
      printf "%s=%s\n" "$var" "${!var}"
    done
  ' _ "$TEST_REPO_ROOT" "$LINEAR_SH" "$SCOPE_SH"
}

# ---------------------------------------------------------------------------
# 1. .ralph.json 'projects' list → RALPH_PROJECTS is newline-joined string
# ---------------------------------------------------------------------------
@test ".ralph.json projects list exports RALPH_PROJECTS newline-joined" {
  run source_scope

  [ "$status" -eq 0 ]
  # env separates entries with newlines; a multi-line RALPH_PROJECTS value
  # spans multiple lines in the output until the next RALPH_* name appears.
  if [[ "$output" != *"RALPH_PROJECTS=Project A"* ]]; then
    echo "RALPH_PROJECTS missing first project, got: $output" >&2
    return 1
  fi
  if [[ "$output" != *"Project B"* ]]; then
    echo "RALPH_PROJECTS missing second project, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 2. Missing .ralph.json → hard error
# ---------------------------------------------------------------------------
@test "missing .ralph.json exits 1 with helpful error" {
  rm -f "$TEST_REPO_ROOT/.ralph.json"

  run bash -c "cd '$TEST_REPO_ROOT' && source '$LINEAR_SH' && source '$SCOPE_SH'" 2>&1
  [ "$status" -eq 1 ]
  if [[ "$output" != *".ralph.json"* ]]; then
    echo "expected '.ralph.json' in error, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 3. Empty projects list in .ralph.json → hard error
# ---------------------------------------------------------------------------
@test "empty projects list exits 1 with error" {
  cat > "$TEST_REPO_ROOT/.ralph.json" <<'EOF'
{
  "projects": []
}
EOF

  run bash -c "cd '$TEST_REPO_ROOT' && source '$LINEAR_SH' && source '$SCOPE_SH'" 2>&1
  [ "$status" -eq 1 ]
  if [[ "$output" != *"empty"* ]] && [[ "$output" != *"projects"* ]]; then
    echo "expected 'empty' or 'projects' in error, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 4. Both projects and initiative set → hard error
# ---------------------------------------------------------------------------
@test "both projects and initiative set exits 1" {
  cat > "$TEST_REPO_ROOT/.ralph.json" <<'EOF'
{
  "projects": ["Project A"],
  "initiative": "Some Initiative"
}
EOF

  run bash -c "cd '$TEST_REPO_ROOT' && source '$LINEAR_SH' && source '$SCOPE_SH'" 2>&1
  [ "$status" -eq 1 ]
  if [[ "$output" != *"both"* ]]; then
    echo "expected 'both' in error (projects + initiative), got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 5. Neither projects nor initiative set → hard error
# ---------------------------------------------------------------------------
@test "neither projects nor initiative exits 1" {
  cat > "$TEST_REPO_ROOT/.ralph.json" <<'EOF'
{}
EOF

  run bash -c "cd '$TEST_REPO_ROOT' && source '$LINEAR_SH' && source '$SCOPE_SH'" 2>&1
  [ "$status" -eq 1 ]
  if [[ "$output" != *"projects"* ]] && [[ "$output" != *"initiative"* ]]; then
    echo "expected 'projects' or 'initiative' in error, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 6. .ralph.json with `initiative` key → scope.sh expands via
#    linear_list_initiative_projects (sourced from lib/linear.sh) and
#    exports the resolved project list as RALPH_PROJECTS.
# ---------------------------------------------------------------------------
@test ".ralph.json initiative expands via linear to RALPH_PROJECTS" {
  cat > "$TEST_REPO_ROOT/.ralph.json" <<'EOF'
{
  "initiative": "Demo Initiative"
}
EOF

  # Stub `linear` in PATH to return a controlled GraphQL response. The stub
  # returns two projects for any `linear api` call.
  local stub_dir="$TEST_REPO_ROOT/_stub_bin"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/linear" <<'STUB'
#!/usr/bin/env bash
printf '%s' '{"data":{"initiatives":{"nodes":[{"name":"Demo Initiative","projects":{"pageInfo":{"hasNextPage":false},"nodes":[{"name":"Alpha"},{"name":"Beta"}]}}]}}}'
STUB
  chmod +x "$stub_dir/linear"

  run bash -c '
    cd "$1"
    export PATH="$2:$PATH"
    source "$3" || exit $?
    source "$4" || exit $?
    for var in $(compgen -v RALPH_); do
      printf "%s=%s\n" "$var" "${!var}"
    done
  ' _ "$TEST_REPO_ROOT" "$stub_dir" "$LINEAR_SH" "$SCOPE_SH"

  [ "$status" -eq 0 ]
  if [[ "$output" != *"Alpha"* ]]; then
    echo "RALPH_PROJECTS missing Alpha, got: $output" >&2
    return 1
  fi
  if [[ "$output" != *"Beta"* ]]; then
    echo "RALPH_PROJECTS missing Beta, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 7. Initiative that resolves to zero projects → hard error
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
    source "$4"
  ' _ "$TEST_REPO_ROOT" "$stub_dir" "$LINEAR_SH" "$SCOPE_SH" 2>&1

  [ "$status" -ne 0 ]
  if [[ "$output" != *"zero projects"* ]]; then
    echo "expected 'zero projects' in error, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 8. RALPH_SCOPE_LOADED is a tuple "<repo-root-abs-path>|<scope-hash>".
#    Entry-point scripts gate auto-source on this marker so repeat invocations
#    in the same shell don't re-source scope.sh unless either the repo root
#    changed OR .ralph.json content changed.
# ---------------------------------------------------------------------------
@test "RALPH_SCOPE_LOADED is a tuple of repo-root and scope-hash" {
  run source_scope

  [ "$status" -eq 0 ]
  if [[ "$output" != *"RALPH_SCOPE_LOADED="*"|"* ]]; then
    echo "RALPH_SCOPE_LOADED should contain '|', got: $output" >&2
    return 1
  fi
  if [[ "$output" != *"$TEST_REPO_ROOT"* ]]; then
    echo "tuple should contain repo root '$TEST_REPO_ROOT', got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 9. scope.sh sources cleanly from zsh.
#    Claude Code's Bash tool dispatches commands through /bin/zsh -c on
#    macOS, so skill-doc snippets that source scope.sh trip on bash-only
#    constructs. This test reproduces the failure mode: zsh-side source
#    must succeed and export RALPH_PROJECTS.
# ---------------------------------------------------------------------------
@test "scope.sh sources cleanly from zsh" {
  command -v zsh >/dev/null || skip "zsh not installed"

  run zsh -c "
    cd '$TEST_REPO_ROOT'
    source '$LINEAR_SH' || exit 10
    source '$SCOPE_SH' || exit 11
    printf 'PROJECTS=%s\n' \"\$RALPH_PROJECTS\"
  " 2>&1

  [ "$status" -eq 0 ]
  if [[ "$output" != *"PROJECTS=Project A"* ]]; then
    echo "expected PROJECTS=Project A, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 10. scope.sh fails loudly if linear.sh was not pre-sourced. Guards against
#     callers (e.g. future skill-doc snippets) that forget the order
#     dependency — without the guard, the .ralph.json initiative path would
#     hit a late "command not found" on linear_list_initiative_projects,
#     which is much harder to trace than a load-time error.
# ---------------------------------------------------------------------------
@test "scope.sh fails loudly if linear.sh not pre-sourced" {
  run bash -c "cd '$TEST_REPO_ROOT' && source '$SCOPE_SH'" 2>&1
  [ "$status" -eq 1 ]
  if [[ "$output" != *"linear.sh"* ]]; then
    echo "expected 'linear.sh' in error, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 11. default_base_branch absent → RALPH_DEFAULT_BASE_BRANCH defaults to "main".
#     Preserves today's behavior for every existing .ralph.json.
# ---------------------------------------------------------------------------
@test "default_base_branch absent defaults RALPH_DEFAULT_BASE_BRANCH to main" {
  run source_scope

  [ "$status" -eq 0 ]
  if [[ "$output" != *"RALPH_DEFAULT_BASE_BRANCH=main"* ]]; then
    echo "expected RALPH_DEFAULT_BASE_BRANCH=main, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 12. default_base_branch set → exports the configured value.
# ---------------------------------------------------------------------------
@test "default_base_branch set exports the configured value" {
  cat > "$TEST_REPO_ROOT/.ralph.json" <<'EOF'
{
  "projects": ["Project A"],
  "default_base_branch": "dev"
}
EOF

  run source_scope

  [ "$status" -eq 0 ]
  if [[ "$output" != *"RALPH_DEFAULT_BASE_BRANCH=dev"* ]]; then
    echo "expected RALPH_DEFAULT_BASE_BRANCH=dev, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 13. default_base_branch empty string → hard error. Forces operators to omit
#     the key rather than silently defaulting an empty string to a git ref.
# ---------------------------------------------------------------------------
@test "default_base_branch empty string exits 1 with error" {
  cat > "$TEST_REPO_ROOT/.ralph.json" <<'EOF'
{
  "projects": ["Project A"],
  "default_base_branch": ""
}
EOF

  run bash -c "cd '$TEST_REPO_ROOT' && source '$LINEAR_SH' && source '$SCOPE_SH'" 2>&1
  [ "$status" -eq 1 ]
  if [[ "$output" != *"default_base_branch"* ]]; then
    echo "expected 'default_base_branch' in error, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 14. default_base_branch as JSON number → hard error. Catches type confusion
#     at load time rather than letting it leak to git-ref resolution.
# ---------------------------------------------------------------------------
@test "default_base_branch as number exits 1 with error" {
  cat > "$TEST_REPO_ROOT/.ralph.json" <<'EOF'
{
  "projects": ["Project A"],
  "default_base_branch": 123
}
EOF

  run bash -c "cd '$TEST_REPO_ROOT' && source '$LINEAR_SH' && source '$SCOPE_SH'" 2>&1
  [ "$status" -eq 1 ]
  if [[ "$output" != *"default_base_branch"* ]]; then
    echo "expected 'default_base_branch' in error, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 15. default_base_branch as JSON boolean → hard error.
# ---------------------------------------------------------------------------
@test "default_base_branch as boolean exits 1 with error" {
  cat > "$TEST_REPO_ROOT/.ralph.json" <<'EOF'
{
  "projects": ["Project A"],
  "default_base_branch": false
}
EOF

  run bash -c "cd '$TEST_REPO_ROOT' && source '$LINEAR_SH' && source '$SCOPE_SH'" 2>&1
  [ "$status" -eq 1 ]
  if [[ "$output" != *"default_base_branch"* ]]; then
    echo "expected 'default_base_branch' in error, got: $output" >&2
    return 1
  fi
}
