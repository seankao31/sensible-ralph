#!/usr/bin/env bats
# Tests for skills/close-issue/scripts/cleanup_coord_dep.sh.
# Mocks the `linear` CLI via PATH and stubs the helpers (linear_label_exists,
# linear_remove_label, linear_get_issue_blockers) via a fake lib/linear.sh.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HELPER="$SCRIPT_DIR/cleanup_coord_dep.sh"

setup() {
  STUB_PLUGIN_ROOT="$(mktemp -d)"
  export STUB_PLUGIN_ROOT
  export CLAUDE_PLUGIN_ROOT="$STUB_PLUGIN_ROOT"

  mkdir -p "$STUB_PLUGIN_ROOT/lib"

  # Stub lib/linear.sh — define the helpers the cleanup script consumes.
  cat > "$STUB_PLUGIN_ROOT/lib/linear.sh" <<'LINEARSH'
linear_label_exists() {
  local name="$1"
  local safe; safe="$(printf '%s' "$name" | tr '-' '_')"
  local rc_var="STUB_LABEL_EXISTS_${safe}"
  return "${!rc_var:-${STUB_DEFAULT_LABEL_EXISTS:-0}}"
}

linear_remove_label() {
  if [[ -n "${STUB_REMOVE_LABEL_FAIL:-}" ]]; then
    return 1
  fi
  printf '%s\n' "$1 $2" >> "${STUB_REMOVE_LABEL_LOG:-/dev/null}"
  return 0
}

linear_get_issue_blockers() {
  if [[ -n "${STUB_BLOCKERS_FAIL:-}" ]]; then
    return 1
  fi
  printf '%s' "${STUB_BLOCKERS_JSON:-[]}"
}
LINEARSH

  # Stub `linear` for `linear api ...` (comment query) and
  # `linear issue relation delete ...` (per-parent delete attempts).
  STUB_DELETE_LOG="$STUB_PLUGIN_ROOT/relation_delete_args"
  export STUB_DELETE_LOG
  : > "$STUB_DELETE_LOG"
  STUB_API_CALLS="$STUB_PLUGIN_ROOT/api_calls"
  export STUB_API_CALLS
  : > "$STUB_API_CALLS"

  cat > "$STUB_PLUGIN_ROOT/linear" <<'LINEAR_BIN'
#!/usr/bin/env bash
case "$1" in
  api)
    cat > /dev/null  # drain stdin
    printf '1\n' >> "$STUB_API_CALLS"
    if [[ -n "${STUB_API_FAIL:-}" ]]; then
      exit 1
    fi
    printf '%s' "${STUB_API_OUTPUT:-}"
    ;;
  issue)
    if [[ "$2" == "relation" && "$3" == "delete" ]]; then
      printf '%s\n' "$4 $5 $6" >> "$STUB_DELETE_LOG"
      # Default: pretend each delete succeeds. STUB_DELETE_FAIL_<parent>
      # (with hyphens→underscores) makes the named parent fail.
      parent="$6"
      safe="$(printf '%s' "$parent" | tr '-' '_')"
      fail_var="STUB_DELETE_FAIL_${safe}"
      if [[ -n "${!fail_var:-}" ]]; then
        exit 1
      fi
      exit 0
    fi
    ;;
  *)
    exit 0
    ;;
esac
LINEAR_BIN
  chmod +x "$STUB_PLUGIN_ROOT/linear"
  export PATH="$STUB_PLUGIN_ROOT:$PATH"

  STUB_REMOVE_LABEL_LOG="$STUB_PLUGIN_ROOT/remove_label_args"
  export STUB_REMOVE_LABEL_LOG
  : > "$STUB_REMOVE_LABEL_LOG"

  export ISSUE_ID="ENG-100"
  export CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL="ralph-coord-dep"
  export STUB_DEFAULT_LABEL_EXISTS="0"
}

teardown() {
  rm -rf "$STUB_PLUGIN_ROOT"
}

# Build a Linear-shape `comments` GraphQL response from a list of bodies.
# Usage: build_comments_response "<body1>" "<body2>" ...
# Sets STUB_API_OUTPUT.
set_comments_response() {
  local nodes='[]'
  local i=0
  for body in "$@"; do
    i=$((i + 1))
    local node; node="$(jq -nc --arg id "c$i" --arg body "$body" '{id: $id, body: $body}')"
    nodes="$(printf '%s' "$nodes" | jq -c --argjson n "$node" '. + [$n]')"
  done
  STUB_API_OUTPUT="$(jq -nc --argjson nodes "$nodes" \
    '{data: {issue: {comments: {pageInfo: {hasNextPage: false}, nodes: $nodes}}}}')"
  export STUB_API_OUTPUT
}

# ---------------------------------------------------------------------------
# 1. Zero matching comments → label-remove still attempted, exit 0
# ---------------------------------------------------------------------------
@test "zero matching comments: attempts label remove and exits 0" {
  set_comments_response  # no comments
  export STUB_BLOCKERS_JSON='[]'

  run "$HELPER"

  [ "$status" -eq 0 ]
  # linear_remove_label was called (label was reported as existing).
  grep -qF "ENG-100 ralph-coord-dep" "$STUB_REMOVE_LABEL_LOG"
  # No relation deletes attempted.
  [ ! -s "$STUB_DELETE_LOG" ]
}

# ---------------------------------------------------------------------------
# 2. Multi-comment dedup: parent in two comments collapses to one delete
# ---------------------------------------------------------------------------
@test "multi-comment dedup collapses repeats to one delete per parent" {
  body1=$'**Coord deps**\n\n```coord-dep-audit\n{"parents":["ENG-201","ENG-202"]}\n```\n'
  body2=$'**Coord deps**\n\n```coord-dep-audit\n{"parents":["ENG-201"]}\n```\n'
  set_comments_response "$body1" "$body2"
  export STUB_BLOCKERS_JSON='[]'

  run "$HELPER"

  [ "$status" -eq 0 ]
  # ENG-201 appears in both comments — must be deleted once, not twice.
  c201="$(grep -c "blocked-by ENG-201" "$STUB_DELETE_LOG")"
  c202="$(grep -c "blocked-by ENG-202" "$STUB_DELETE_LOG")"
  [ "$c201" -eq 1 ]
  [ "$c202" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 3. Bullet text or inline mention is NOT extracted
# ---------------------------------------------------------------------------
@test "bullet text and inline coord-dep-audit are NOT delete authority" {
  body=$'**Coord deps**\n\n- blocked-by ENG-301 — surface\n- blocked-by ENG-302 — also surface\n\nThis prose says `coord-dep-audit` inline.\n'
  set_comments_response "$body"
  export STUB_BLOCKERS_JSON='[]'

  run "$HELPER"

  # Without a fenced ```coord-dep-audit block, parents stays empty AND
  # fenced_block_count is 0 → clean fast path → exit 0, no deletes.
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_DELETE_LOG" ]
}

# ---------------------------------------------------------------------------
# 4. One malformed block among valid: malformed silently skipped, valid
#    block's parents extracted and deleted.
# ---------------------------------------------------------------------------
@test "one malformed block among valid: valid parents still extracted" {
  body=$'```coord-dep-audit\nthis-is-not-json\n```\n\n```coord-dep-audit\n{"parents":["ENG-401"]}\n```\n'
  set_comments_response "$body"
  export STUB_BLOCKERS_JSON='[]'

  run "$HELPER"

  [ "$status" -eq 0 ]
  c401="$(grep -c "blocked-by ENG-401" "$STUB_DELETE_LOG")"
  [ "$c401" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 5. All malformed blocks: keep label, exit 1
# ---------------------------------------------------------------------------
@test "all-malformed blocks: keep label, exit 1" {
  body=$'```coord-dep-audit\nnot-json-1\n```\n\n```coord-dep-audit\nnot-json-2\n```\n'
  set_comments_response "$body"
  export STUB_BLOCKERS_JSON='[]'

  run "$HELPER"

  [ "$status" -eq 1 ]
  [[ "$output" == *"audit block(s) found"* ]]
  [[ "$output" == *"KEEPING coord-dep label"* ]]
  # No label removal attempted.
  [ ! -s "$STUB_REMOVE_LABEL_LOG" ]
  # No relation deletes attempted (we never reached step 4).
  [ ! -s "$STUB_DELETE_LOG" ]
}

# ---------------------------------------------------------------------------
# 6. pageInfo.hasNextPage=true → exit 1 loud
# ---------------------------------------------------------------------------
@test "page truncation aborts loud (exit 1)" {
  STUB_API_OUTPUT='{"data":{"issue":{"comments":{"pageInfo":{"hasNextPage":true},"nodes":[]}}}}'
  export STUB_API_OUTPUT
  export STUB_BLOCKERS_JSON='[]'

  run "$HELPER"

  [ "$status" -eq 1 ]
  [[ "$output" == *"silent truncation refused"* ]] || [[ "$output" == *"more than 250"* ]]
}

# ---------------------------------------------------------------------------
# 7. Per-comment awk isolation: unclosed fence in comment 1 does NOT consume
#    comment 2's body; comment 2's valid block still extracts.
# ---------------------------------------------------------------------------
@test "per-comment awk isolation: unclosed fence does not poison next comment" {
  # Comment 1 has an OPEN-only ```coord-dep-audit fence (no closing ```).
  body1=$'```coord-dep-audit\n{"parents":["ENG-901"]}\n'
  # Comment 2 has a clean fence with a different parent.
  body2=$'```coord-dep-audit\n{"parents":["ENG-902"]}\n```\n'
  set_comments_response "$body1" "$body2"
  export STUB_BLOCKERS_JSON='[]'

  run "$HELPER"

  [ "$status" -eq 0 ]
  # Comment 2's valid parent must be extracted and deleted.
  grep -qF "blocked-by ENG-902" "$STUB_DELETE_LOG"
  # Comment 1's would-have-been parent (had its fence been closed in
  # comment 2) must not bleed across — at most ENG-901 from its OWN
  # streamed content. The point of the test is comment 2 stays clean.
  c902="$(grep -c "blocked-by ENG-902" "$STUB_DELETE_LOG")"
  [ "$c902" -eq 1 ]
}

# ---------------------------------------------------------------------------
# 8. Concurrent-UI A: parent absent pre AND post → exit 0
# ---------------------------------------------------------------------------
@test "concurrent-UI A: parent absent pre and post, success exit 0" {
  body=$'```coord-dep-audit\n{"parents":["ENG-501"]}\n```\n'
  set_comments_response "$body"
  # Post-delete blockers list is empty (parent never was there).
  export STUB_BLOCKERS_JSON='[]'

  run "$HELPER"

  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 9. Concurrent-UI B: parent present pre, delete returns non-zero, but
#    post-delete re-fetch shows it absent → success (no real failure).
# ---------------------------------------------------------------------------
@test "concurrent-UI B: delete fails but post-fetch shows absent → exit 0" {
  body=$'```coord-dep-audit\n{"parents":["ENG-601"]}\n```\n'
  set_comments_response "$body"
  # Make the per-call delete return non-zero (operator removed it via UI
  # between our query and our delete attempt).
  export STUB_DELETE_FAIL_ENG_601=1
  # Post-delete blockers: empty.
  export STUB_BLOCKERS_JSON='[]'

  run "$HELPER"

  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 10. Real failure: parent still present after delete → exit 1, label kept
# ---------------------------------------------------------------------------
@test "real failure: parent present in post-delete fetch → exit 1, label kept" {
  body=$'```coord-dep-audit\n{"parents":["ENG-701"]}\n```\n'
  set_comments_response "$body"
  # Even though the delete call "succeeded", post-fetch shows it stuck.
  export STUB_BLOCKERS_JSON='[{"id":"ENG-701"}]'

  run "$HELPER"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ENG-701 still present"* ]]
  [[ "$output" == *"coord-dep label kept"* ]]
  # No label removal attempted on the failure path.
  [ ! -s "$STUB_REMOVE_LABEL_LOG" ]
}

# ---------------------------------------------------------------------------
# 11. Workspace label missing on success path: skip remove, log, exit 0
# ---------------------------------------------------------------------------
@test "workspace label missing on success path: remove skipped, exit 0" {
  set_comments_response  # zero comments
  export STUB_BLOCKERS_JSON='[]'
  export STUB_DEFAULT_LABEL_EXISTS=1   # workspace label not present

  run "$HELPER"

  [ "$status" -eq 0 ]
  [[ "$output" == *"not present — skipping"* ]]
  # Label-remove was NOT called.
  [ ! -s "$STUB_REMOVE_LABEL_LOG" ]
}

# ---------------------------------------------------------------------------
# 12. GraphQL response-shape failure → non-zero exit (must NOT be masked
#     as "no edges").
# ---------------------------------------------------------------------------
@test "GraphQL response-shape failure: exit 1, label kept" {
  STUB_API_OUTPUT='{"errors":[{"message":"bad query"}]}'
  export STUB_API_OUTPUT
  export STUB_BLOCKERS_JSON='[]'

  run "$HELPER"

  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected GraphQL response shape"* ]]
  [ ! -s "$STUB_REMOVE_LABEL_LOG" ]
  [ ! -s "$STUB_DELETE_LOG" ]
}

# ---------------------------------------------------------------------------
# 13. Comment query CLI failure → exit 1, label kept
# ---------------------------------------------------------------------------
@test "comment query CLI failure: exit 1, label kept" {
  export STUB_API_FAIL=1
  export STUB_BLOCKERS_JSON='[]'

  run "$HELPER"

  [ "$status" -eq 1 ]
  [[ "$output" == *"comment query failed"* ]]
  [ ! -s "$STUB_REMOVE_LABEL_LOG" ]
  [ ! -s "$STUB_DELETE_LOG" ]
}

# ---------------------------------------------------------------------------
# 14. Post-delete linear_get_issue_blockers fails → exit 1 conservatively
# ---------------------------------------------------------------------------
@test "post-delete blockers query fails: exit 1, label kept" {
  body=$'```coord-dep-audit\n{"parents":["ENG-801"]}\n```\n'
  set_comments_response "$body"
  export STUB_BLOCKERS_FAIL=1

  run "$HELPER"

  [ "$status" -eq 1 ]
  [[ "$output" == *"post-delete linear_get_issue_blockers failed"* ]]
  [ ! -s "$STUB_REMOVE_LABEL_LOG" ]
}
