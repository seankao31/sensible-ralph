#!/usr/bin/env bash
# Coordination-dependency backstop scan helper for /sr-start step 2.
#
# Pure data assembly: emits a single JSON bundle on stdout that the skill
# prose then reasons over. Does NOT write to Linear; ALL Linear mutations
# happen in /sr-start step 2's per-child write loop after operator
# confirmation. Sibling helper to skills/sr-spec/scripts/coord_dep_scan.sh
# (ENG-280); naming carries the "backstop scan" language so a `grep
# coord_dep` distinguishes the two without inspecting directories.
#
# Audit-comment format consumed at write time (canonical, single source of
# truth — both /sr-spec step 12 and /sr-start step 2 emit the same shape;
# /close-issue step 8 parses it):
#
#   **Coordination dependencies added by /sr-start scan**
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
# Usage:
#   coord_dep_backstop_scan.sh
#
# Inputs:
#   No positional args. Unlike ENG-280's helper which takes a new-spec path
#   and PREREQS as the anchor for an asymmetric scan, this helper has no
#   anchor — the entire Approved set is symmetric and every peer is
#   simultaneously a candidate child and parent.
#
# Env:
#   $SENSIBLE_RALPH_PROJECTS              — newline-joined project scope
#   $CLAUDE_PLUGIN_OPTION_APPROVED_STATE  — Approved state name
#   $CLAUDE_PLUGIN_OPTION_FAILED_LABEL    — failed-label name
#
# Output (stdout): single JSON object —
#   {
#     "approved": [
#       {
#         "id": "ENG-A",
#         "title": "...",
#         "description": "<full body, verbatim>",
#         "existing_blockers": ["ENG-X", "ENG-Y"]
#       },
#       ...
#     ]
#   }
#
# Cost: O(N) Linear CLI calls per scan, where N = Approved-set size. Each
# peer is two CLI calls (view + blockers); typical N ≤ 10, so total
# wall-clock is 5–15 seconds. Comparable to preflight_scan.sh.
#
# Exit codes:
#   0 — success (approved may be empty or singleton; caller's fast-path
#       handles those cases in skill prose)
#   1 — Linear CLI failure listing peers, viewing any peer, or fetching
#       any peer's blockers. Stderr names the offending peer ID. Fail-fast
#       over emit-partial: a silently dropped peer would silently miss its
#       overlaps, defeating the step's purpose.

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

# 1. List Approved peers. Same filter build_queue.sh uses (Approved state,
# no ralph-failed label, in scope) so scan and dispatch see identical sets.
peers_raw="$(linear_list_approved_issues)" || {
  printf 'coord_dep_backstop_scan: linear_list_approved_issues failed\n' >&2
  exit 1
}

peer_ids=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  peer_ids+=("$line")
done <<< "$peers_raw"

# 2. For each peer: capture title + description verbatim, plus existing
# blocked-by parent IDs (regardless of those parents' state — relationship
# existence is what gates the covered-pairs filter, not parent state).
approved_json='[]'
for peer in ${peer_ids[@]+"${peer_ids[@]}"}; do
  view_json="$(linear issue view "$peer" --json --no-comments 2>/dev/null)" || {
    printf 'coord_dep_backstop_scan: failed to fetch peer %s\n' "$peer" >&2
    exit 1
  }

  blockers_json="$(linear_get_issue_blockers "$peer")" || {
    printf 'coord_dep_backstop_scan: failed to get blockers for %s\n' "$peer" >&2
    exit 1
  }

  blockers_ids_json="$(printf '%s' "$blockers_json" | jq -c '[.[].id]')" || {
    printf 'coord_dep_backstop_scan: failed to parse blockers for %s\n' "$peer" >&2
    exit 1
  }

  peer_obj="$(printf '%s' "$view_json" | jq -c \
    --arg id "$peer" \
    --argjson blockers "$blockers_ids_json" \
    '{id: $id, title: (.title // ""), description: (.description // ""), existing_blockers: $blockers}')" \
    || {
      printf 'coord_dep_backstop_scan: failed to assemble peer object for %s\n' "$peer" >&2
      exit 1
    }
  approved_json="$(printf '%s' "$approved_json" | jq -c --argjson obj "$peer_obj" '. + [$obj]')"
done

# 3. Emit the bundle.
jq -n --argjson approved "$approved_json" '{approved: $approved}'
