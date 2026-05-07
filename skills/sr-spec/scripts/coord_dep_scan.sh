#!/usr/bin/env bash
# Coordination-dependency scan helper for /sr-spec step 11.
#
# Pure data assembly: emits a single JSON bundle on stdout that the skill
# prose then reasons over. Does NOT write to Linear; ALL Linear mutations
# happen at /sr-spec step 12 after operator confirmation.
#
# Audit-comment format (canonical, single source of truth — both /sr-spec
# step 12 and /close-issue step 8 reference this header):
#
#   **Coordination dependencies added by /sr-spec scan**
#
#   - blocked-by ENG-X — <one-line rationale>
#   - blocked-by ENG-Y — <one-line rationale>
#
#   ```coord-dep-audit
#   {"parents": ["ENG-X", "ENG-Y"]}
#   ```
#
#   Will be removed automatically on /close-issue.
#
# /close-issue's cleanup parses ONLY the ```coord-dep-audit fenced block
# (per-block jq, isolated per comment); bullet lines are NOT delete authority.
#
# Usage:
#   coord_dep_scan.sh <spec-file> [PREREQ_ID ...]
#
# Inputs:
#   $1                                   — absolute path to the new spec file
#   $2..$N                               — design-time PREREQS (issue IDs)
#   ISSUE_ID                             — current spec's Linear issue id
#   SENSIBLE_RALPH_PROJECTS              — newline-joined project scope
#   CLAUDE_PLUGIN_OPTION_APPROVED_STATE  — Approved state name
#   CLAUDE_PLUGIN_OPTION_FAILED_LABEL    — failed-label name
#
# Output (stdout): single JSON object —
#   {
#     "issue_id": "ENG-280",
#     "new_spec": { "path": "docs/specs/<topic>.md", "body": "..." },
#     "peers": [ { "id": "ENG-X", "title": "...", "description": "..." } ],
#     "existing_blockers": ["ENG-A", "ENG-B"]
#   }
#
# Exit codes:
#   0 — success (peers may be empty)
#   1 — Linear CLI failure listing peers or viewing any peer
#   2 — new spec file does not exist at the passed path

set -euo pipefail

# Idempotent re-source of the plugin libs the helper depends on. The skill
# should already have sourced them, but a stand-alone invocation (manual
# debug, autonomous probe) might not. Mirror the scope-loaded gate from
# preflight_scan.sh — re-sourcing scope.sh re-reads .sensible-ralph.json,
# so skip when the marker still matches this repo's scope content hash.
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  # shellcheck source=/dev/null
  source "$CLAUDE_PLUGIN_ROOT/lib/linear.sh"

  RESOLVED_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || RESOLVED_REPO_ROOT=""
  RESOLVED_SCOPE_HASH=""
  if [[ -n "$RESOLVED_REPO_ROOT" && -f "$RESOLVED_REPO_ROOT/.sensible-ralph.json" ]]; then
    RESOLVED_SCOPE_HASH="$(shasum -a 1 < "$RESOLVED_REPO_ROOT/.sensible-ralph.json" | awk '{print $1}')"
  fi
  EXPECTED_SCOPE_LOADED="${RESOLVED_REPO_ROOT}|${RESOLVED_SCOPE_HASH}"
  if [[ "${SENSIBLE_RALPH_SCOPE_LOADED:-}" != "$EXPECTED_SCOPE_LOADED" ]]; then
    # shellcheck source=/dev/null
    source "$CLAUDE_PLUGIN_ROOT/lib/scope.sh"
  fi
fi

SPEC_FILE="${1:?coord_dep_scan: spec file path required as first arg}"
shift || true
PREREQS=("$@")

if [[ ! -f "$SPEC_FILE" ]]; then
  printf 'coord_dep_scan: step 7 spec file missing at %q\n' "$SPEC_FILE" >&2
  exit 2
fi

if [[ -z "${ISSUE_ID:-}" ]]; then
  printf 'coord_dep_scan: ISSUE_ID env var must be set\n' >&2
  exit 1
fi

# 1. List Approved peers, excluding self.
peers_raw="$(linear_list_approved_issues)" || {
  printf 'coord_dep_scan: linear_list_approved_issues failed\n' >&2
  exit 1
}

peer_ids=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  [[ "$line" == "$ISSUE_ID" ]] && continue
  peer_ids+=("$line")
done <<< "$peers_raw"

# 2. Fetch each peer's title and description.
peers_json='[]'
for peer in ${peer_ids[@]+"${peer_ids[@]}"}; do
  view_json="$(linear issue view "$peer" --json 2>/dev/null)" || {
    printf 'coord_dep_scan: failed to fetch peer %s\n' "$peer" >&2
    exit 1
  }
  peer_obj="$(printf '%s' "$view_json" | jq -c \
    --arg id "$peer" \
    '{id: $id, title: (.title // ""), description: (.description // "")}')" \
    || {
      printf 'coord_dep_scan: failed to parse peer %s\n' "$peer" >&2
      exit 1
    }
  peers_json="$(printf '%s' "$peers_json" | jq -c --argjson obj "$peer_obj" '. + [$obj]')"
done

# 3. Existing blockers — Linear's current blocked-by set unioned with PREREQS.
blockers_json="$(linear_get_issue_blockers "$ISSUE_ID")" || {
  printf 'coord_dep_scan: linear_get_issue_blockers failed for %s\n' "$ISSUE_ID" >&2
  exit 1
}

linear_blocker_ids="$(printf '%s' "$blockers_json" | jq -r '.[].id')"
existing_blockers_json='[]'
existing_blockers_json="$(
  {
    [[ -n "$linear_blocker_ids" ]] && printf '%s\n' "$linear_blocker_ids"
    for p in ${PREREQS[@]+"${PREREQS[@]}"}; do
      printf '%s\n' "$p"
    done
  } | awk 'NF' | sort -u | jq -R . | jq -s '.'
)"

# 4. Read the spec body verbatim.
spec_body_json="$(jq -Rs . < "$SPEC_FILE")"

# 5. Emit the bundle.
jq -n \
  --arg issue_id "$ISSUE_ID" \
  --arg path "$SPEC_FILE" \
  --argjson body "$spec_body_json" \
  --argjson peers "$peers_json" \
  --argjson existing_blockers "$existing_blockers_json" \
  '{
     issue_id: $issue_id,
     new_spec: { path: $path, body: $body },
     peers: $peers,
     existing_blockers: $existing_blockers
   }'
