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

  # Set required env vars (as config.sh would export them).
  # RALPH_PROJECTS is newline-joined; most tests use a single project (same
  # as before the multi-project change), but the multi-project tests below
  # override this.
  export RALPH_PROJECTS="Agent Config"
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

@test "linear_list_approved_issues queries each project in RALPH_PROJECTS" {
  # Smart stub: emits different IDs depending on --project value so we can
  # verify the union spans both projects.
  cat > "$STUB_DIR/linear" <<'STUB'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$STUB_ARGS_FILE"
printf '\n' >> "$STUB_ARGS_FILE"
project=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--project" ]]; then project="$2"; shift 2; else shift; fi
done
case "$project" in
  "Agent Config") printf '%s' '{"nodes":[{"identifier":"ENG-100","state":{"name":"Approved"},"labels":{"nodes":[]}}]}' ;;
  "Machine Config") printf '%s' '{"nodes":[{"identifier":"ENG-200","state":{"name":"Approved"},"labels":{"nodes":[]}}]}' ;;
  *) printf '%s' '{"nodes":[]}' ;;
esac
STUB
  chmod +x "$STUB_DIR/linear"

  export RALPH_PROJECTS=$'Agent Config\nMachine Config'

  run call_fn linear_list_approved_issues

  [ "$status" -eq 0 ]
  if [[ "$output" != *"ENG-100"* ]]; then
    echo "missing ENG-100 from Agent Config, got: $output" >&2
    return 1
  fi
  if [[ "$output" != *"ENG-200"* ]]; then
    echo "missing ENG-200 from Machine Config, got: $output" >&2
    return 1
  fi
  # Verify one call per project — two linear invocations total
  local call_count; call_count="$(grep -c "^issue query" "$STUB_ARGS_FILE")"
  [ "$call_count" -eq 2 ]
}

@test "linear_list_approved_issues fails if any project query fails" {
  cat > "$STUB_DIR/linear" <<'STUB'
#!/usr/bin/env bash
printf '%q ' "$@" >> "$STUB_ARGS_FILE"
printf '\n' >> "$STUB_ARGS_FILE"
project=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--project" ]]; then project="$2"; shift 2; else shift; fi
done
if [[ "$project" == "Bad" ]]; then
  exit 1
fi
printf '%s' '{"nodes":[]}'
STUB
  chmod +x "$STUB_DIR/linear"

  export RALPH_PROJECTS=$'Agent Config\nBad'

  run call_fn linear_list_approved_issues

  [ "$status" -ne 0 ]
  if [[ "$output" != *"Bad"* ]]; then
    echo "expected failing project name 'Bad' in error, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 1b. linear_list_initiative_projects — expand an initiative name to its
#     member project names via `linear api` GraphQL. Used by config.sh when
#     .ralph.json carries an `initiative` key instead of a `projects` list.
# ---------------------------------------------------------------------------
@test "linear_list_initiative_projects returns newline-joined project names" {
  STUB_OUTPUT='{"data":{"initiatives":{"nodes":[{"name":"AI Collab","projects":{"pageInfo":{"hasNextPage":false},"nodes":[{"name":"Agent Config"},{"name":"I Said Yes"}]}}]}}}'
  export STUB_OUTPUT

  run call_fn linear_list_initiative_projects "AI Collab"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Agent Config"* ]]
  [[ "$output" == *"I Said Yes"* ]]
}

@test "linear_list_initiative_projects passes the initiative name as GraphQL variable" {
  STUB_OUTPUT='{"data":{"initiatives":{"nodes":[{"name":"X","projects":{"pageInfo":{"hasNextPage":false},"nodes":[{"name":"P1"}]}}]}}}'
  export STUB_OUTPUT

  call_fn linear_list_initiative_projects X

  grep -q "^api " "$STUB_ARGS_FILE"
  grep -qF "initiativeName=X" "$STUB_ARGS_FILE"
}

@test "linear_list_initiative_projects fails when no initiative matches" {
  STUB_OUTPUT='{"data":{"initiatives":{"nodes":[]}}}'
  export STUB_OUTPUT

  run call_fn linear_list_initiative_projects "Does Not Exist"

  [ "$status" -ne 0 ]
  if [[ "$output" != *"no initiative"* ]]; then
    echo "expected 'no initiative' in error, got: $output" >&2
    return 1
  fi
}

@test "linear_list_initiative_projects fails when multiple initiatives match" {
  STUB_OUTPUT='{"data":{"initiatives":{"nodes":[{"name":"Dup","projects":{"pageInfo":{"hasNextPage":false},"nodes":[{"name":"A"}]}},{"name":"Dup","projects":{"pageInfo":{"hasNextPage":false},"nodes":[{"name":"B"}]}}]}}}'
  export STUB_OUTPUT

  run call_fn linear_list_initiative_projects Dup

  [ "$status" -ne 0 ]
  if [[ "$output" != *"multiple initiatives"* ]]; then
    echo "expected 'multiple initiatives' in error, got: $output" >&2
    return 1
  fi
}

@test "linear_list_initiative_projects fails loud if projects page is truncated" {
  # A Linear initiative with >50 projects would silently truncate; preflight
  # and build_queue would then work on an incomplete scope.
  STUB_OUTPUT='{"data":{"initiatives":{"nodes":[{"name":"Big","projects":{"pageInfo":{"hasNextPage":true},"nodes":[{"name":"P1"}]}}]}}}'
  export STUB_OUTPUT

  run call_fn linear_list_initiative_projects Big

  [ "$status" -ne 0 ]
  if [[ "$output" != *"truncation"* ]] && [[ "$output" != *"more than 50"* ]]; then
    echo "expected truncation error, got: $output" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 2. linear_get_issue_blockers — single GraphQL call via `linear api`,
#    filters inverseRelations to type=="blocks" client-side via jq.
# ---------------------------------------------------------------------------
@test "linear_get_issue_blockers returns empty array when no blocked-by relations" {
  # GraphQL response with no nodes — issue has no inverseRelations
  STUB_OUTPUT='{"data":{"issue":{"inverseRelations":{"nodes":[]}}}}'
  export STUB_OUTPUT

  run call_fn linear_get_issue_blockers ENG-20

  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "linear_get_issue_blockers filters out non-blocks relation types" {
  # GraphQL response includes related/duplicate relations — these must be filtered out
  STUB_OUTPUT='{"data":{"issue":{"inverseRelations":{"nodes":[
    {"type":"related","issue":{"identifier":"ENG-30","branchName":"eng-30","state":{"name":"Done"}}},
    {"type":"duplicate","issue":{"identifier":"ENG-31","branchName":"eng-31","state":{"name":"Done"}}}
  ]}}}}'
  export STUB_OUTPUT

  run call_fn linear_get_issue_blockers ENG-21

  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "linear_get_issue_blockers returns JSON array of blockers" {
  STUB_OUTPUT='{"data":{"issue":{"inverseRelations":{"nodes":[
    {"type":"blocks","issue":{"identifier":"ENG-15","branchName":"eng-15-blocker-title","state":{"name":"Done"},"project":{"id":"p1","name":"Agent Config"}}}
  ]}}}}'
  export STUB_OUTPUT

  run call_fn linear_get_issue_blockers ENG-21

  [ "$status" -eq 0 ]
  [[ "$output" == *'"id":"ENG-15"'* ]]
  [[ "$output" == *'"state":"Done"'* ]]
  [[ "$output" == *'"branch":"eng-15-blocker-title"'* ]]
  [[ "$output" == *'"project":"Agent Config"'* ]]
}

@test "linear_get_issue_blockers returns empty string project when blocker has no project" {
  # Linear issues can be projectless; the field coerces to "" so downstream
  # string comparisons don't need to special-case JSON null.
  STUB_OUTPUT='{"data":{"issue":{"inverseRelations":{"nodes":[
    {"type":"blocks","issue":{"identifier":"ENG-66","branchName":"eng-66","state":{"name":"Done"},"project":null}}
  ]}}}}'
  export STUB_OUTPUT

  run call_fn linear_get_issue_blockers ENG-67

  [ "$status" -eq 0 ]
  [[ "$output" == *'"project":""'* ]]
}

@test "linear_get_issue_blockers calls linear api with the issue id as variable" {
  STUB_OUTPUT='{"data":{"issue":{"inverseRelations":{"nodes":[]}}}}'
  export STUB_OUTPUT

  call_fn linear_get_issue_blockers ENG-22

  grep -q "^api " "$STUB_ARGS_FILE"
  grep -qF "issueId=ENG-22" "$STUB_ARGS_FILE"
}

@test "linear_get_issue_blockers fails loud if Linear truncates the relation page" {
  # Simulate Linear returning hasNextPage=true (issue has > 250 inverseRelations).
  # Silent truncation would make downstream consumers (preflight, build_queue,
  # dag_base) work from an incomplete dependency set — refuse instead.
  STUB_OUTPUT='{"data":{"issue":{"inverseRelations":{"pageInfo":{"hasNextPage":true},"nodes":[
    {"type":"blocks","issue":{"identifier":"ENG-100","branchName":"eng-100","state":{"name":"Done"}}}
  ]}}}}'
  export STUB_OUTPUT

  run call_fn linear_get_issue_blockers ENG-99

  [ "$status" -ne 0 ]
  [[ "$output" == *"truncation"* ]] || [[ "$output" == *"more than 250"* ]]
}

@test "linear_get_issue_blockers returns multiple blockers in a single call" {
  STUB_OUTPUT='{"data":{"issue":{"inverseRelations":{"nodes":[
    {"type":"blocks","issue":{"identifier":"ENG-16","branchName":"eng-16-a","state":{"name":"In Progress"}}},
    {"type":"blocks","issue":{"identifier":"ENG-17","branchName":"eng-17-b","state":{"name":"Done"}}}
  ]}}}}'
  export STUB_OUTPUT

  run call_fn linear_get_issue_blockers ENG-23

  [ "$status" -eq 0 ]
  [[ "$output" == *'"id":"ENG-16"'* ]]
  [[ "$output" == *'"id":"ENG-17"'* ]]

  # Single linear api call, not one per blocker
  local api_calls; api_calls="$(grep -c "^api " "$STUB_ARGS_FILE")"
  [ "$api_calls" -eq 1 ]
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
