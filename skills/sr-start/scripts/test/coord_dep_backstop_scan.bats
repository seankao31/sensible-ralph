#!/usr/bin/env bats
# Tests for skills/sr-start/scripts/coord_dep_backstop_scan.sh.
# Stubs `lib/linear.sh` (the helpers the script sources) and the `linear`
# CLI (for `linear issue view <id> --json --no-comments`) via PATH.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HELPER="$SCRIPT_DIR/coord_dep_backstop_scan.sh"

setup() {
  STUB_PLUGIN_ROOT="$(mktemp -d)"
  export STUB_PLUGIN_ROOT
  export CLAUDE_PLUGIN_ROOT="$STUB_PLUGIN_ROOT"

  mkdir -p "$STUB_PLUGIN_ROOT/lib"

  # Stub lib/linear.sh — define just what the helper consumes:
  #   linear_list_approved_issues, linear_get_issue_blockers.
  # Per-peer behaviors:
  #   STUB_BLOCKERS_<id>_JSON  — JSON array (default '[]')
  #   STUB_BLOCKERS_<id>_FAIL  — set non-empty to force linear_get_issue_blockers exit 1
  cat > "$STUB_PLUGIN_ROOT/lib/linear.sh" <<'LINEAR_SH'
linear_list_approved_issues() {
  if [[ -n "${STUB_APPROVED_FAIL:-}" ]]; then
    return 1
  fi
  printf '%s' "${STUB_APPROVED_IDS:-}"
}

linear_get_issue_blockers() {
  local issue_id="$1"
  local safe; safe="$(printf '%s' "$issue_id" | tr '-' '_')"
  local fail_var="STUB_BLOCKERS_${safe}_FAIL"
  if [[ -n "${!fail_var:-}" ]]; then
    printf 'linear_get_issue_blockers: stub failure for %s\n' "$issue_id" >&2
    return 1
  fi
  local json_var="STUB_BLOCKERS_${safe}_JSON"
  printf '%s' "${!json_var:-[]}"
}
LINEAR_SH

  # Skip the scope.sh re-source — set the marker to whatever the current repo
  # would resolve to so the helper's auto-source gate matches.
  RESOLVED_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || RESOLVED_REPO_ROOT=""
  RESOLVED_SCOPE_HASH=""
  if [[ -n "$RESOLVED_REPO_ROOT" && -f "$RESOLVED_REPO_ROOT/.sensible-ralph.json" ]]; then
    RESOLVED_SCOPE_HASH="$(shasum -a 1 < "$RESOLVED_REPO_ROOT/.sensible-ralph.json" | awk '{print $1}')"
  fi
  export SENSIBLE_RALPH_SCOPE_LOADED="${RESOLVED_REPO_ROOT}|${RESOLVED_SCOPE_HASH}"

  # Env vars the plugin harness exports (consumed by linear_list_approved_issues).
  export SENSIBLE_RALPH_PROJECTS="Test Project"
  export CLAUDE_PLUGIN_OPTION_APPROVED_STATE="Approved"
  export CLAUDE_PLUGIN_OPTION_FAILED_LABEL="ralph-failed"

  # Stub the `linear` CLI for `linear issue view <id> --json --no-comments`.
  # Per-issue behaviors:
  #   STUB_PEER_TITLE_<id_with_dashes_as_underscores>
  #   STUB_PEER_DESC_<id_with_dashes_as_underscores>
  #   STUB_PEER_VIEW_FAIL_<id_with_dashes_as_underscores>  (set non-empty to fail)
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
}

teardown() {
  rm -rf "$STUB_PLUGIN_ROOT"
}

# ---------------------------------------------------------------------------
# 1. Empty Approved set → approved: [], exit 0
# ---------------------------------------------------------------------------
@test "empty Approved set yields approved: [] and exit 0" {
  export STUB_APPROVED_IDS=""

  run "$HELPER"

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.approved == []' > /dev/null
}

# ---------------------------------------------------------------------------
# 2. Singleton Approved set → array of length 1, exit 0
# ---------------------------------------------------------------------------
@test "singleton Approved set yields array of length 1" {
  export STUB_APPROVED_IDS="ENG-281"
  export STUB_PEER_TITLE_ENG_281="Backstop scan"
  export STUB_PEER_DESC_ENG_281="Backstop description body."
  # No blockers JSON env var set → defaults to '[]'.

  run "$HELPER"

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.approved | length == 1' > /dev/null
  echo "$output" | jq -e '.approved[0].id == "ENG-281"' > /dev/null
  echo "$output" | jq -e '.approved[0].title == "Backstop scan"' > /dev/null
  echo "$output" | jq -e '.approved[0].existing_blockers == []' > /dev/null
}

# ---------------------------------------------------------------------------
# 3. Multiple peers — descriptions verbatim, blockers populated per-peer
# ---------------------------------------------------------------------------
@test "multiple peers produce per-peer entries with verbatim descriptions and blockers" {
  export STUB_APPROVED_IDS=$'ENG-100\nENG-200\nENG-300'

  export STUB_PEER_TITLE_ENG_100="Spec A"
  export STUB_PEER_DESC_ENG_100=$'# A\n\nTouches lib/foo.sh.'

  export STUB_PEER_TITLE_ENG_200="Spec B"
  export STUB_PEER_DESC_ENG_200=$'# B\n\nRenames lib/foo.sh → lib/internal/foo.sh.'

  export STUB_PEER_TITLE_ENG_300="Spec C"
  export STUB_PEER_DESC_ENG_300=$'# C\n\nIndependent.'

  # ENG-300 is blocked-by ENG-100; the others have empty blocker sets.
  export STUB_BLOCKERS_ENG_100_JSON='[]'
  export STUB_BLOCKERS_ENG_200_JSON='[]'
  export STUB_BLOCKERS_ENG_300_JSON='[{"id":"ENG-100","state":"Approved","branch":"eng-100","project":"Test Project"}]'

  run "$HELPER"

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.approved | length == 3' > /dev/null

  # Descriptions verbatim.
  desc_a="$(echo "$output" | jq -r '.approved[] | select(.id == "ENG-100") | .description')"
  [ "$desc_a" = $'# A\n\nTouches lib/foo.sh.' ]

  desc_b="$(echo "$output" | jq -r '.approved[] | select(.id == "ENG-200") | .description')"
  [ "$desc_b" = $'# B\n\nRenames lib/foo.sh \xe2\x86\x92 lib/internal/foo.sh.' ]

  # Per-peer existing_blockers populated correctly.
  blockers_a="$(echo "$output" | jq -r '.approved[] | select(.id == "ENG-100") | .existing_blockers | join(",")')"
  [ "$blockers_a" = "" ]

  blockers_c="$(echo "$output" | jq -r '.approved[] | select(.id == "ENG-300") | .existing_blockers | join(",")')"
  [ "$blockers_c" = "ENG-100" ]
}

# ---------------------------------------------------------------------------
# 4. Empty-description peer is preserved with empty string
# ---------------------------------------------------------------------------
@test "empty-description peer preserved with empty string" {
  export STUB_APPROVED_IDS="ENG-281"
  export STUB_PEER_TITLE_ENG_281="Peer Title"
  # No STUB_PEER_DESC_ENG_281 → stub emits empty string.

  run "$HELPER"

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.approved[0].description == ""' > /dev/null
  echo "$output" | jq -e '.approved[0].title == "Peer Title"' > /dev/null
}

# ---------------------------------------------------------------------------
# 5. linear_list_approved_issues failure → exit 1
# ---------------------------------------------------------------------------
@test "linear_list_approved_issues failure exits 1" {
  export STUB_APPROVED_FAIL=1

  run "$HELPER"

  [ "$status" -eq 1 ]
  [[ "$output" == *"linear_list_approved_issues failed"* ]]
}

# ---------------------------------------------------------------------------
# 6. Per-peer linear issue view failure → exit 1, names the offending peer
# ---------------------------------------------------------------------------
@test "peer view failure exits 1 with peer id in message" {
  export STUB_APPROVED_IDS="ENG-281"
  export STUB_PEER_VIEW_FAIL_ENG_281=1

  run "$HELPER"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ENG-281"* ]]
}

# ---------------------------------------------------------------------------
# 7. Per-peer linear_get_issue_blockers failure → exit 1, names the peer
# ---------------------------------------------------------------------------
@test "peer get-blockers failure exits 1 with peer id in message" {
  export STUB_APPROVED_IDS="ENG-281"
  export STUB_PEER_TITLE_ENG_281="Peer"
  export STUB_BLOCKERS_ENG_281_FAIL=1

  run "$HELPER"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ENG-281"* ]]
}

# ---------------------------------------------------------------------------
# 8. existing_blockers preserve parent IDs regardless of state
#    (Approved, Done, Canceled, Backlog all surfaced — relationship-existence
#    is what matters, not parent state)
# ---------------------------------------------------------------------------
@test "existing_blockers include parents in any state" {
  export STUB_APPROVED_IDS="ENG-281"
  export STUB_PEER_TITLE_ENG_281="Peer"
  # Three blockers in three different states.
  export STUB_BLOCKERS_ENG_281_JSON='[
    {"id":"ENG-A","state":"Approved","branch":"eng-a","project":"Test Project"},
    {"id":"ENG-B","state":"Done","branch":"eng-b","project":"Test Project"},
    {"id":"ENG-C","state":"Canceled","branch":"eng-c","project":"Test Project"}
  ]'

  run "$HELPER"

  [ "$status" -eq 0 ]
  ids="$(echo "$output" | jq -r '.approved[0].existing_blockers | sort | join(",")')"
  [ "$ids" = "ENG-A,ENG-B,ENG-C" ]
}

# ---------------------------------------------------------------------------
# 9. Self-referential edge case: a peer with itself in existing_blockers
#    (impossible in Linear by construction, defensively tested) is preserved
#    as-is. The skill prose's pair filter excludes self-pairs.
# ---------------------------------------------------------------------------
@test "self-referential blocker is preserved as-is" {
  export STUB_APPROVED_IDS="ENG-281"
  export STUB_PEER_TITLE_ENG_281="Peer"
  export STUB_BLOCKERS_ENG_281_JSON='[{"id":"ENG-281","state":"Approved","branch":"eng-281","project":"Test Project"}]'

  run "$HELPER"

  [ "$status" -eq 0 ]
  ids="$(echo "$output" | jq -r '.approved[0].existing_blockers | join(",")')"
  [ "$ids" = "ENG-281" ]
}

# ---------------------------------------------------------------------------
# 10. Output is a single JSON object with the documented shape
# ---------------------------------------------------------------------------
@test "output shape: object with approved array of {id,title,description,existing_blockers}" {
  export STUB_APPROVED_IDS="ENG-281"
  export STUB_PEER_TITLE_ENG_281="P"
  export STUB_PEER_DESC_ENG_281="body"

  run "$HELPER"

  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "object" and has("approved")' > /dev/null
  echo "$output" | jq -e '.approved[0] | has("id") and has("title") and has("description") and has("existing_blockers")' > /dev/null
  echo "$output" | jq -e '.approved[0].existing_blockers | type == "array"' > /dev/null
}

# ---------------------------------------------------------------------------
# 11. Helper takes no positional args — passing one is ignored
#     (No anchor by spec; symmetry over the Approved set is the contract.)
# ---------------------------------------------------------------------------
@test "helper ignores positional args (no anchor)" {
  export STUB_APPROVED_IDS="ENG-281"
  export STUB_PEER_TITLE_ENG_281="P"

  run "$HELPER" SOME_IGNORED_ARG

  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.approved[0].id == "ENG-281"' > /dev/null
}
