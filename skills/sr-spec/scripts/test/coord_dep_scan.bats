#!/usr/bin/env bats
# Tests for skills/sr-spec/scripts/coord_dep_scan.sh.
# Stubs the `linear` CLI via PATH and uses a scope-loaded marker so the
# helper does not try to re-read .sensible-ralph.json from the repo.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HELPER="$SCRIPT_DIR/coord_dep_scan.sh"

setup() {
  STUB_PLUGIN_ROOT="$(mktemp -d)"
  export STUB_PLUGIN_ROOT
  export CLAUDE_PLUGIN_ROOT="$STUB_PLUGIN_ROOT"

  # Plugin lib structure the helper sources from.
  mkdir -p "$STUB_PLUGIN_ROOT/lib"

  # Stub lib/linear.sh — define just what the helper consumes:
  #   linear_list_approved_issues, linear_get_issue_blockers.
  # `linear` (the binary) is stubbed via PATH below for `linear issue view`.
  cat > "$STUB_PLUGIN_ROOT/lib/linear.sh" <<'LINEAR_SH'
linear_list_approved_issues() {
  if [[ -n "${STUB_APPROVED_FAIL:-}" ]]; then
    return 1
  fi
  printf '%s' "${STUB_APPROVED_IDS:-}"
}

linear_get_issue_blockers() {
  if [[ -n "${STUB_BLOCKERS_FAIL:-}" ]]; then
    return 1
  fi
  printf '%s' "${STUB_BLOCKERS_JSON:-[]}"
}
LINEAR_SH

  # Skip the scope.sh re-source (no .sensible-ralph.json in the temp root).
  RESOLVED_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || RESOLVED_REPO_ROOT=""
  RESOLVED_SCOPE_HASH=""
  if [[ -n "$RESOLVED_REPO_ROOT" && -f "$RESOLVED_REPO_ROOT/.sensible-ralph.json" ]]; then
    RESOLVED_SCOPE_HASH="$(shasum -a 1 < "$RESOLVED_REPO_ROOT/.sensible-ralph.json" | awk '{print $1}')"
  fi
  export SENSIBLE_RALPH_SCOPE_LOADED="${RESOLVED_REPO_ROOT}|${RESOLVED_SCOPE_HASH}"

  # Env vars the plugin harness exports.
  export SENSIBLE_RALPH_PROJECTS="Test Project"
  export CLAUDE_PLUGIN_OPTION_APPROVED_STATE="Approved"
  export CLAUDE_PLUGIN_OPTION_FAILED_LABEL="ralph-failed"

  # Stub the `linear` CLI for `linear issue view <id> --json`.
  # Per-issue behavior: STUB_PEER_TITLE_<ENG_NN>, STUB_PEER_DESC_<ENG_NN>,
  # STUB_PEER_VIEW_FAIL_<ENG_NN> (set to non-empty to make view exit 1).
  cat > "$STUB_PLUGIN_ROOT/linear" <<'LINEAR_BIN'
#!/usr/bin/env bash
issue_id=""
for arg in "$@"; do
  if [[ "$arg" == ENG-* ]]; then
    issue_id="$arg"
    break
  fi
done

safe="$(printf '%s' "$issue_id" | tr '-' '_')"

fail_var="STUB_PEER_VIEW_FAIL_${safe}"
if [[ -n "${!fail_var:-}" ]]; then
  exit 1
fi

title_var="STUB_PEER_TITLE_${safe}"
desc_var="STUB_PEER_DESC_${safe}"
title="${!title_var:-Title for $issue_id}"
desc="${!desc_var:-}"

jq -n --arg t "$title" --arg d "$desc" '{title: $t, description: $d}'
LINEAR_BIN
  chmod +x "$STUB_PLUGIN_ROOT/linear"
  export PATH="$STUB_PLUGIN_ROOT:$PATH"

  # A working spec file fixture (overridden per-test where needed).
  SPEC_DIR="$(mktemp -d)"
  SPEC_FILE="$SPEC_DIR/spec.md"
  printf '# Test Spec\n\nBody text.\n' > "$SPEC_FILE"
  export SPEC_DIR SPEC_FILE
}

teardown() {
  rm -rf "$STUB_PLUGIN_ROOT" "$SPEC_DIR"
}

# ---------------------------------------------------------------------------
# 1. Empty peer list → peers: [], exit 0
# ---------------------------------------------------------------------------
@test "empty peer list yields peers: [] and exit 0" {
  export ISSUE_ID="ENG-280"
  export STUB_APPROVED_IDS=""
  export STUB_BLOCKERS_JSON='[]'

  run "$HELPER" "$SPEC_FILE"

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.peers == []' > /dev/null
  echo "$output" | jq -e '.existing_blockers == []' > /dev/null
}

# ---------------------------------------------------------------------------
# 2. Self-exclusion: $ISSUE_ID never appears in peers[]
# ---------------------------------------------------------------------------
@test "self-exclusion: ISSUE_ID is filtered from peers" {
  export ISSUE_ID="ENG-280"
  # Approved set includes self plus one peer.
  export STUB_APPROVED_IDS=$'ENG-280\nENG-281'
  export STUB_BLOCKERS_JSON='[]'
  export STUB_PEER_TITLE_ENG_281="Backstop scan"
  export STUB_PEER_DESC_ENG_281="Backstop description body."

  run "$HELPER" "$SPEC_FILE"

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.peers | length == 1' > /dev/null
  echo "$output" | jq -e '.peers[0].id == "ENG-281"' > /dev/null
  # ENG-280 must not appear in peers.
  ! echo "$output" | jq -e '.peers[] | select(.id == "ENG-280")' > /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 3. Peer descriptions captured verbatim
# ---------------------------------------------------------------------------
@test "peer description appears verbatim in peers[].description" {
  export ISSUE_ID="ENG-280"
  export STUB_APPROVED_IDS="ENG-281"
  export STUB_BLOCKERS_JSON='[]'
  export STUB_PEER_TITLE_ENG_281="Peer Title"
  # Multi-line, contains markdown that must round-trip.
  export STUB_PEER_DESC_ENG_281=$'# Heading\n\nLine with `code` and "quotes".'

  run "$HELPER" "$SPEC_FILE"

  [ "$status" -eq 0 ]
  desc="$(echo "$output" | jq -r '.peers[0].description')"
  [ "$desc" = $'# Heading\n\nLine with `code` and "quotes".' ]
}

# ---------------------------------------------------------------------------
# 4. Empty-description peer is preserved (description: "")
# ---------------------------------------------------------------------------
@test "empty-description peer is preserved with empty string" {
  export ISSUE_ID="ENG-280"
  export STUB_APPROVED_IDS="ENG-281"
  export STUB_BLOCKERS_JSON='[]'
  export STUB_PEER_TITLE_ENG_281="Peer Title"
  # No STUB_PEER_DESC_ENG_281 set → stub emits empty string.

  run "$HELPER" "$SPEC_FILE"

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.peers[0].description == ""' > /dev/null
  echo "$output" | jq -e '.peers[0].title == "Peer Title"' > /dev/null
}

# ---------------------------------------------------------------------------
# 5. existing_blockers = union of Linear blocked-by + PREREQS, deduplicated
# ---------------------------------------------------------------------------
@test "existing_blockers unions Linear blockers with PREREQS args, dedup'd" {
  export ISSUE_ID="ENG-280"
  export STUB_APPROVED_IDS="ENG-281"
  # Pre-existing blockers in Linear: ENG-A, ENG-B.
  export STUB_BLOCKERS_JSON='[{"id":"ENG-A"},{"id":"ENG-B"}]'
  export STUB_PEER_TITLE_ENG_281="P"

  # Pass PREREQS positional args: ENG-B (overlap) and ENG-C (new).
  run "$HELPER" "$SPEC_FILE" ENG-B ENG-C

  [ "$status" -eq 0 ]
  blockers="$(echo "$output" | jq -r '.existing_blockers | sort | join(",")')"
  [ "$blockers" = "ENG-A,ENG-B,ENG-C" ]
}

# ---------------------------------------------------------------------------
# 6. Pre-existing blocker overlapping a peer — peer still appears in peers[]
#    (the helper does NOT pre-filter peers against existing_blockers; the
#    skill prose handles that step in sub-step 5).
# ---------------------------------------------------------------------------
@test "pre-existing blocker overlapping a peer leaves peer in peers[]" {
  export ISSUE_ID="ENG-280"
  export STUB_APPROVED_IDS="ENG-281"
  # ENG-281 is already a blocker in Linear.
  export STUB_BLOCKERS_JSON='[{"id":"ENG-281"}]'
  export STUB_PEER_TITLE_ENG_281="Pre-blocker peer"
  export STUB_PEER_DESC_ENG_281="body"

  run "$HELPER" "$SPEC_FILE"

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.peers[0].id == "ENG-281"' > /dev/null
  echo "$output" | jq -e '.existing_blockers | index("ENG-281") != null' > /dev/null
}

# ---------------------------------------------------------------------------
# 7. Missing spec file → exit 2 with "spec file missing"
# ---------------------------------------------------------------------------
@test "missing spec file exits 2 with diagnostic" {
  export ISSUE_ID="ENG-280"
  export STUB_APPROVED_IDS=""
  export STUB_BLOCKERS_JSON='[]'

  run "$HELPER" "/nonexistent/path/to/spec.md"

  [ "$status" -eq 2 ]
  [[ "$output" == *"spec file missing"* ]]
}

# ---------------------------------------------------------------------------
# 8. linear_list_approved_issues failure → exit 1
# ---------------------------------------------------------------------------
@test "linear list-approved failure exits 1" {
  export ISSUE_ID="ENG-280"
  export STUB_APPROVED_FAIL=1

  run "$HELPER" "$SPEC_FILE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"linear_list_approved_issues failed"* ]]
}

# ---------------------------------------------------------------------------
# 9. linear_get_issue_blockers failure → exit 1
# ---------------------------------------------------------------------------
@test "linear_get_issue_blockers failure exits 1" {
  export ISSUE_ID="ENG-280"
  export STUB_APPROVED_IDS=""
  export STUB_BLOCKERS_FAIL=1

  run "$HELPER" "$SPEC_FILE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"linear_get_issue_blockers failed"* ]]
}

# ---------------------------------------------------------------------------
# 10. peer view failure → exit 1
# ---------------------------------------------------------------------------
@test "peer view failure exits 1 with peer id in message" {
  export ISSUE_ID="ENG-280"
  export STUB_APPROVED_IDS="ENG-281"
  export STUB_BLOCKERS_JSON='[]'
  export STUB_PEER_VIEW_FAIL_ENG_281=1

  run "$HELPER" "$SPEC_FILE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to fetch peer ENG-281"* ]]
}

# ---------------------------------------------------------------------------
# 11. new_spec.body contains the spec contents verbatim
# ---------------------------------------------------------------------------
@test "new_spec.body contains the spec file contents" {
  export ISSUE_ID="ENG-280"
  export STUB_APPROVED_IDS=""
  export STUB_BLOCKERS_JSON='[]'

  printf '# Title\n\n- item 1\n- item 2\n' > "$SPEC_FILE"

  run "$HELPER" "$SPEC_FILE"

  [ "$status" -eq 0 ]
  # Compare the JSON-encoded body to preserve the trailing newline (which
  # bash's $() command substitution strips from a captured string).
  body_encoded="$(echo "$output" | jq -c '.new_spec.body')"
  [ "$body_encoded" = '"# Title\n\n- item 1\n- item 2\n"' ]
  path="$(echo "$output" | jq -r '.new_spec.path')"
  [ "$path" = "$SPEC_FILE" ]
}
