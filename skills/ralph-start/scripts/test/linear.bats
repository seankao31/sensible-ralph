#!/usr/bin/env bats
# Tests for scripts/lib/linear.sh
# Uses a stub linear CLI to avoid real API calls.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LINEAR_SH="$SCRIPT_DIR/lib/linear.sh"

# ---------------------------------------------------------------------------
# Setup: create a temp dir for the stub + args capture file, prepend to PATH
# ---------------------------------------------------------------------------
setup() {
  STUB_DIR="$(mktemp -d)"
  STUB_ARGS_FILE="$STUB_DIR/linear_args"
  export STUB_ARGS_FILE

  # Default stub output — overridden per-test via STUB_OUTPUT
  STUB_OUTPUT=""
  export STUB_OUTPUT

  # Write stub linear script
  cat > "$STUB_DIR/linear" <<'STUB'
#!/usr/bin/env bash
# Record all argv to the args file (shell-quoted, space-separated, newline-terminated)
printf '%q ' "$@" >> "$STUB_ARGS_FILE"
printf '\n' >> "$STUB_ARGS_FILE"
# Emit the configured output
printf '%s' "$STUB_OUTPUT"
exit "${STUB_EXIT:-0}"
STUB
  chmod +x "$STUB_DIR/linear"

  # Prepend stub dir to PATH so our stub takes priority
  export PATH="$STUB_DIR:$PATH"

  # Set required env vars (as config.sh would export them)
  export RALPH_PROJECT="Agent Config"
  export RALPH_APPROVED_STATE="Approved"
  export RALPH_FAILED_LABEL="ralph-failed"
}

teardown() {
  rm -rf "$STUB_DIR"
}

# ---------------------------------------------------------------------------
# Helper: source linear.sh and call a function in a subshell, capturing output
# ---------------------------------------------------------------------------
call_fn() {
  local fn_name="$1"; shift
  bash -c "source '$LINEAR_SH' && $fn_name $*"
}

# ---------------------------------------------------------------------------
# 1. linear_list_approved_issues — queries with correct flags, filters by state
# ---------------------------------------------------------------------------
@test "linear_list_approved_issues calls linear with correct flags" {
  STUB_OUTPUT='{"nodes": [{"identifier": "ENG-10", "state": {"name": "Approved", "type": "unstarted"}, "labels": {"nodes": []}}, {"identifier": "ENG-11", "state": {"name": "In Progress", "type": "started"}, "labels": {"nodes": []}}]}'
  export STUB_OUTPUT

  run call_fn linear_list_approved_issues

  [ "$status" -eq 0 ]
  # Should have called: linear issue query --project "Agent Config" --all-teams --limit 0 --json
  grep -q "issue query" "$STUB_ARGS_FILE"
  grep -q -- "--all-teams" "$STUB_ARGS_FILE"
  grep -q -- "--limit" "$STUB_ARGS_FILE"
  grep -qF -- "--limit 0" "$STUB_ARGS_FILE"
  grep -q -- "--json" "$STUB_ARGS_FILE"
}

@test "linear_list_approved_issues returns only Approved issues" {
  STUB_OUTPUT='{"nodes": [{"identifier": "ENG-10", "state": {"name": "Approved", "type": "unstarted"}, "labels": {"nodes": []}}, {"identifier": "ENG-11", "state": {"name": "In Progress", "type": "started"}, "labels": {"nodes": []}}]}'
  export STUB_OUTPUT

  run call_fn linear_list_approved_issues

  [ "$status" -eq 0 ]
  [[ "$output" == *"ENG-10"* ]]
  [[ "$output" != *"ENG-11"* ]]
}

@test "linear_list_approved_issues excludes issues with the failed label" {
  STUB_OUTPUT='{"nodes": [{"identifier": "ENG-10", "state": {"name": "Approved", "type": "unstarted"}, "labels": {"nodes": []}}, {"identifier": "ENG-12", "state": {"name": "Approved", "type": "unstarted"}, "labels": {"nodes": [{"name": "ralph-failed"}]}}]}'
  export STUB_OUTPUT

  run call_fn linear_list_approved_issues

  [ "$status" -eq 0 ]
  [[ "$output" == *"ENG-10"* ]]
  [[ "$output" != *"ENG-12"* ]]
}

@test "linear_list_approved_issues returns empty output when no approved issues" {
  STUB_OUTPUT='{"nodes": []}'
  export STUB_OUTPUT

  run call_fn linear_list_approved_issues

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 2. linear_get_issue_blockers — parses relation list, fetches state+branch
# ---------------------------------------------------------------------------
@test "linear_get_issue_blockers returns empty array when no blocked-by relations" {
  # Stub: relation list returns no incoming blocked-by
  STUB_OUTPUT="Relations for ENG-20: Some title

Outgoing:
  ENG-20 related ENG-30: Other

"
  export STUB_OUTPUT

  run call_fn linear_get_issue_blockers ENG-20

  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "linear_get_issue_blockers returns JSON array of blockers" {
  # We need the stub to behave differently for `relation list` vs `issue view`.
  # Override STUB_OUTPUT to be empty (won't work for multi-call).
  # Write a smarter stub.
  cat > "$STUB_DIR/linear" <<'STUB'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$STUB_ARGS_FILE"
printf '\n' >> "$STUB_ARGS_FILE"
if [[ "$*" == *"relation list"* ]]; then
  printf 'Relations for ENG-21: Title\n\nIncoming:\n  ENG-21 blocked-by ENG-15: Blocker\n'
elif [[ "$*" == *"view ENG-15"* ]]; then
  printf '{"identifier": "ENG-15", "branchName": "eng-15-blocker-title", "state": {"name": "Done"}}'
fi
STUB
  chmod +x "$STUB_DIR/linear"

  run call_fn linear_get_issue_blockers ENG-21

  [ "$status" -eq 0 ]
  [[ "$output" == *'"id": "ENG-15"'* ]]
  [[ "$output" == *'"state": "Done"'* ]]
  [[ "$output" == *'"branch": "eng-15-blocker-title"'* ]]
}

@test "linear_get_issue_blockers calls relation list with correct issue id" {
  # Simple relation list call, no blockers
  STUB_OUTPUT="Relations for ENG-22: Title

"
  export STUB_OUTPUT

  call_fn linear_get_issue_blockers ENG-22

  grep -q "relation list ENG-22" "$STUB_ARGS_FILE"
}

@test "linear_get_issue_blockers calls issue view for each blocker" {
  cat > "$STUB_DIR/linear" <<'STUB'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$STUB_ARGS_FILE"
printf '\n' >> "$STUB_ARGS_FILE"
if [[ "$*" == *"relation list"* ]]; then
  printf 'Relations for ENG-23: Title\n\nIncoming:\n  ENG-23 blocked-by ENG-16: A\n  ENG-23 blocked-by ENG-17: B\n'
elif [[ "$*" == *"view ENG-16"* ]]; then
  printf '{"identifier": "ENG-16", "branchName": "eng-16-a", "state": {"name": "In Progress"}}'
elif [[ "$*" == *"view ENG-17"* ]]; then
  printf '{"identifier": "ENG-17", "branchName": "eng-17-b", "state": {"name": "Done"}}'
fi
STUB
  chmod +x "$STUB_DIR/linear"

  run call_fn linear_get_issue_blockers ENG-23

  [ "$status" -eq 0 ]
  grep -q "view ENG-16" "$STUB_ARGS_FILE"
  grep -q "view ENG-17" "$STUB_ARGS_FILE"
  # Output should be a JSON array with 2 entries
  [[ "$output" == *'"id": "ENG-16"'* ]]
  [[ "$output" == *'"id": "ENG-17"'* ]]
}

# ---------------------------------------------------------------------------
# 3. linear_get_issue_branch — calls issue view, returns branchName
# ---------------------------------------------------------------------------
@test "linear_get_issue_branch calls issue view with --json --no-comments" {
  STUB_OUTPUT='{"identifier": "ENG-30", "branchName": "eng-30-some-title", "state": {"name": "Approved"}}'
  export STUB_OUTPUT

  call_fn linear_get_issue_branch ENG-30

  grep -q "issue view ENG-30" "$STUB_ARGS_FILE"
  grep -q -- "--json" "$STUB_ARGS_FILE"
  grep -q -- "--no-comments" "$STUB_ARGS_FILE"
}

@test "linear_get_issue_branch returns the branchName field" {
  STUB_OUTPUT='{"identifier": "ENG-30", "branchName": "eng-30-some-title", "state": {"name": "Approved"}}'
  export STUB_OUTPUT

  run call_fn linear_get_issue_branch ENG-30

  [ "$status" -eq 0 ]
  [ "$output" = "eng-30-some-title" ]
}

# ---------------------------------------------------------------------------
# 4. linear_set_state — calls issue update --state
# ---------------------------------------------------------------------------
@test "linear_set_state calls issue update with correct issue id and state" {
  STUB_OUTPUT=""
  export STUB_OUTPUT

  run call_fn linear_set_state ENG-40 '"In Review"'

  [ "$status" -eq 0 ]
  grep -q "issue update ENG-40" "$STUB_ARGS_FILE"
  grep -q -- "--state" "$STUB_ARGS_FILE"
  grep -qF 'In\ Review' "$STUB_ARGS_FILE"
}

# ---------------------------------------------------------------------------
# 5. linear_add_label — additive: fetches existing labels, re-applies + new
# ---------------------------------------------------------------------------
@test "linear_add_label fetches existing labels via issue view" {
  # Stub: view returns existing labels, update succeeds
  cat > "$STUB_DIR/linear" <<'STUB'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$STUB_ARGS_FILE"
printf '\n' >> "$STUB_ARGS_FILE"
if [[ "$*" == *"view"* ]]; then
  printf '{"identifier": "ENG-50", "branchName": "eng-50-x", "state": {"name": "Approved"}, "labels": {"nodes": [{"name": "existing-label"}]}}'
fi
STUB
  chmod +x "$STUB_DIR/linear"

  run call_fn linear_add_label ENG-50 new-label

  [ "$status" -eq 0 ]
  grep -q "issue view ENG-50" "$STUB_ARGS_FILE"
  grep -q "issue update ENG-50" "$STUB_ARGS_FILE"
}

@test "linear_add_label preserves existing labels and adds new one" {
  cat > "$STUB_DIR/linear" <<'STUB'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$STUB_ARGS_FILE"
printf '\n' >> "$STUB_ARGS_FILE"
if [[ "$*" == *"view"* ]]; then
  printf '{"identifier": "ENG-51", "branchName": "eng-51-x", "state": {"name": "Approved"}, "labels": {"nodes": [{"name": "label-a"}, {"name": "label-b"}]}}'
fi
STUB
  chmod +x "$STUB_DIR/linear"

  run call_fn linear_add_label ENG-51 label-c

  [ "$status" -eq 0 ]
  # The update call should include all three labels
  update_call="$(grep "issue update ENG-51" "$STUB_ARGS_FILE")"
  [[ "$update_call" == *"label-a"* ]]
  [[ "$update_call" == *"label-b"* ]]
  [[ "$update_call" == *"label-c"* ]]
}

@test "linear_add_label works when issue has no existing labels" {
  cat > "$STUB_DIR/linear" <<'STUB'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$STUB_ARGS_FILE"
printf '\n' >> "$STUB_ARGS_FILE"
if [[ "$*" == *"view"* ]]; then
  printf '{"identifier": "ENG-52", "branchName": "eng-52-x", "state": {"name": "Approved"}, "labels": {"nodes": []}}'
fi
STUB
  chmod +x "$STUB_DIR/linear"

  run call_fn linear_add_label ENG-52 only-label

  [ "$status" -eq 0 ]
  update_call="$(grep "issue update ENG-52" "$STUB_ARGS_FILE")"
  [[ "$update_call" == *"only-label"* ]]
}

@test "linear_add_label does not duplicate a label already on the issue" {
  cat > "$STUB_DIR/linear" <<'STUB'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$STUB_ARGS_FILE"
printf '\n' >> "$STUB_ARGS_FILE"
if [[ "$*" == *"view"* ]]; then
  printf '{"identifier": "ENG-53", "branchName": "eng-53-x", "state": {"name": "Approved"}, "labels": {"nodes": [{"name": "label-a"}, {"name": "ralph-failed"}]}}'
fi
STUB
  chmod +x "$STUB_DIR/linear"

  run call_fn linear_add_label ENG-53 ralph-failed

  [ "$status" -eq 0 ]
  update_call="$(grep "issue update ENG-53" "$STUB_ARGS_FILE")"
  # ralph-failed must appear exactly once
  count="$(printf '%s' "$update_call" | grep -o 'ralph-failed' | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 6. linear_comment — calls issue comment add with --body
# ---------------------------------------------------------------------------
@test "linear_comment calls issue comment add with correct args" {
  STUB_OUTPUT=""
  export STUB_OUTPUT

  run call_fn linear_comment ENG-60 '"Build failed due to lint errors"'

  [ "$status" -eq 0 ]
  grep -q "issue comment add ENG-60" "$STUB_ARGS_FILE"
  grep -q -- "--body" "$STUB_ARGS_FILE"
}

@test "linear_comment passes the body text" {
  STUB_OUTPUT=""
  export STUB_OUTPUT

  run call_fn linear_comment ENG-61 '"Hello world"'

  [ "$status" -eq 0 ]
  grep -qF 'Hello\ world' "$STUB_ARGS_FILE"
}
