#!/usr/bin/env bats
# Tests for lib/linear.sh::linear_remove_label.
# Stubs the `linear` CLI via PATH; exercises the real helper, which routes
# through `linear api` for both the label query and the removal mutation,
# and through `linear label list` for the workspace-existence preflight.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LINEAR_SH="$SCRIPT_DIR/linear.sh"

setup() {
  STUB_DIR="$(mktemp -d)"
  STUB_ARGS_FILE="$STUB_DIR/linear_args"
  STUB_STDIN_DIR="$STUB_DIR/stdin"
  mkdir -p "$STUB_STDIN_DIR"
  export STUB_ARGS_FILE STUB_STDIN_DIR

  # Stub linear CLI. The stub dispatches by the first arg:
  #   `linear label list` → emits $STUB_LABEL_LIST_OUTPUT
  #   `linear api`        → emits the next entry from $STUB_API_OUTPUTS_FILE
  #                         (one per line, base64-encoded JSON), defaulting to
  #                         $STUB_API_DEFAULT_OUTPUT when the queue is empty.
  # `linear api` reads the GraphQL document from stdin; the stub captures it
  # to a numbered file under $STUB_STDIN_DIR for assertion.
  cat > "$STUB_DIR/linear" <<'STUB'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$STUB_ARGS_FILE"
printf '\n' >> "$STUB_ARGS_FILE"

case "$1" in
  label)
    if [[ "${STUB_LABEL_LIST_EXIT:-0}" -ne 0 ]]; then
      exit "$STUB_LABEL_LIST_EXIT"
    fi
    printf '%s' "${STUB_LABEL_LIST_OUTPUT:-}"
    ;;
  api)
    # Capture stdin (the GraphQL doc).
    n=$(( $(ls -1 "$STUB_STDIN_DIR" 2>/dev/null | wc -l | tr -d ' ') + 1 ))
    cat > "$STUB_STDIN_DIR/api-$n.graphql"

    # Per-call exit override: STUB_API_EXIT_<n> (1-indexed) takes precedence.
    exit_var="STUB_API_EXIT_${n}"
    rc="${!exit_var:-${STUB_API_EXIT:-0}}"
    if [[ "$rc" -ne 0 ]]; then
      exit "$rc"
    fi

    # Per-call output override: STUB_API_OUTPUT_<n> (1-indexed) takes precedence
    # over the default. Output is a literal JSON string, no encoding.
    out_var="STUB_API_OUTPUT_${n}"
    if [[ -n "${!out_var:-}" ]]; then
      printf '%s' "${!out_var}"
    else
      printf '%s' "${STUB_API_DEFAULT_OUTPUT:-}"
    fi
    ;;
  *)
    : ;;
esac
STUB
  chmod +x "$STUB_DIR/linear"
  export PATH="$STUB_DIR:$PATH"
}

teardown() {
  rm -rf "$STUB_DIR"
}

# Invoke a function in a clean subshell, sourcing linear.sh.
call_fn() {
  local fn_name="$1"; shift
  bash -c "set -euo pipefail; source '$LINEAR_SH' && $fn_name $*"
}

# ---------------------------------------------------------------------------
# 1. Workspace-label-missing diagnostic — refuse loud
# ---------------------------------------------------------------------------
@test "linear_remove_label fails with diagnostic when workspace label missing" {
  # No label matches the name in the workspace.
  export STUB_LABEL_LIST_OUTPUT='{"nodes":[{"id":"abc","name":"other","team":null}],"pageInfo":{"hasNextPage":false}}'

  run call_fn linear_remove_label ENG-100 ralph-coord-dep

  [ "$status" -ne 0 ]
  [[ "$output" == *"workspace label"* ]]
  [[ "$output" == *"ralph-coord-dep"* ]]
  # No api call should have been issued — workspace check came first.
  ! grep -q "^api " "$STUB_ARGS_FILE"
}

# ---------------------------------------------------------------------------
# 2. Idempotent no-op when the label is not on the issue
# ---------------------------------------------------------------------------
@test "linear_remove_label is a no-op (exit 0) when label is not on the issue" {
  export STUB_LABEL_LIST_OUTPUT='{"nodes":[{"id":"L1","name":"ralph-coord-dep","team":null}],"pageInfo":{"hasNextPage":false}}'
  # First api call (label query): issue has labels but not the target.
  export STUB_API_OUTPUT_1='{"data":{"issue":{"id":"issue-uuid","labels":{"nodes":[{"id":"OTHER","name":"some-other-label"}]}}}}'

  run call_fn linear_remove_label ENG-101 ralph-coord-dep

  [ "$status" -eq 0 ]
  # Mutation should NOT have run — only the query.
  api_calls="$(grep -c "^api " "$STUB_ARGS_FILE" || true)"
  [ "$api_calls" -eq 1 ]
  # No mutation file should exist.
  ! grep -l "issueRemoveLabel" "$STUB_STDIN_DIR"/*.graphql > /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 3. Successful removal — label present on issue, mutation succeeds
# ---------------------------------------------------------------------------
@test "linear_remove_label removes the label and exits 0 on success" {
  export STUB_LABEL_LIST_OUTPUT='{"nodes":[{"id":"L1","name":"ralph-coord-dep","team":null}],"pageInfo":{"hasNextPage":false}}'
  export STUB_API_OUTPUT_1='{"data":{"issue":{"id":"issue-uuid","labels":{"nodes":[{"id":"OTHER","name":"some-other-label"},{"id":"COORD","name":"ralph-coord-dep"}]}}}}'
  export STUB_API_OUTPUT_2='{"data":{"issueRemoveLabel":{"success":true}}}'

  run call_fn linear_remove_label ENG-102 ralph-coord-dep

  [ "$status" -eq 0 ]
  # Two api calls: the query and the mutation.
  api_calls="$(grep -c "^api " "$STUB_ARGS_FILE")"
  [ "$api_calls" -eq 2 ]
  # The mutation call should reference the resolved issue UUID and the
  # label UUID — not the human ENG-XXX identifier and not the label name.
  grep -qF "issueId=issue-uuid" "$STUB_ARGS_FILE"
  grep -qF "labelId=COORD" "$STUB_ARGS_FILE"
  # The mutation graphql doc should be the issueRemoveLabel one.
  grep -l "issueRemoveLabel" "$STUB_STDIN_DIR"/*.graphql > /dev/null
}

# ---------------------------------------------------------------------------
# 4. API failure on the lookup — propagate
# ---------------------------------------------------------------------------
@test "linear_remove_label fails with diagnostic when label-lookup api errors" {
  export STUB_LABEL_LIST_OUTPUT='{"nodes":[{"id":"L1","name":"ralph-coord-dep","team":null}],"pageInfo":{"hasNextPage":false}}'
  # First api call fails.
  export STUB_API_EXIT_1=1

  run call_fn linear_remove_label ENG-103 ralph-coord-dep

  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to fetch labels"* ]]
  [[ "$output" == *"ENG-103"* ]]
  [[ "$output" == *"ralph-coord-dep"* ]]
}

# ---------------------------------------------------------------------------
# 5. API failure on the mutation — propagate
# ---------------------------------------------------------------------------
@test "linear_remove_label fails with diagnostic when mutation api errors" {
  export STUB_LABEL_LIST_OUTPUT='{"nodes":[{"id":"L1","name":"ralph-coord-dep","team":null}],"pageInfo":{"hasNextPage":false}}'
  # First call: label query succeeds; second (mutation) fails.
  export STUB_API_OUTPUT_1='{"data":{"issue":{"id":"u1","labels":{"nodes":[{"id":"COORD","name":"ralph-coord-dep"}]}}}}'
  export STUB_API_EXIT_2=1

  run call_fn linear_remove_label ENG-104 ralph-coord-dep

  [ "$status" -ne 0 ]
  [[ "$output" == *"API mutation failed"* ]]
  [[ "$output" == *"ENG-104"* ]]
  [[ "$output" == *"ralph-coord-dep"* ]]
}

# ---------------------------------------------------------------------------
# 6. Mutation reported success: false → fail
# ---------------------------------------------------------------------------
@test "linear_remove_label fails when mutation returns success: false" {
  export STUB_LABEL_LIST_OUTPUT='{"nodes":[{"id":"L1","name":"ralph-coord-dep","team":null}],"pageInfo":{"hasNextPage":false}}'
  export STUB_API_OUTPUT_1='{"data":{"issue":{"id":"u1","labels":{"nodes":[{"id":"COORD","name":"ralph-coord-dep"}]}}}}'
  export STUB_API_OUTPUT_2='{"data":{"issueRemoveLabel":{"success":false}}}'

  run call_fn linear_remove_label ENG-105 ralph-coord-dep

  [ "$status" -ne 0 ]
  [[ "$output" == *"reported failure"* ]]
}

# ---------------------------------------------------------------------------
# 7. Issue uuid missing in response — fail loud
# ---------------------------------------------------------------------------
@test "linear_remove_label fails when issue UUID is missing from query response" {
  export STUB_LABEL_LIST_OUTPUT='{"nodes":[{"id":"L1","name":"ralph-coord-dep","team":null}],"pageInfo":{"hasNextPage":false}}'
  # Issue object is null (e.g., not found).
  export STUB_API_OUTPUT_1='{"data":{"issue":null}}'

  run call_fn linear_remove_label ENG-106 ralph-coord-dep

  [ "$status" -ne 0 ]
  [[ "$output" == *"could not resolve issue uuid"* ]]
}
