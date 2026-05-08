#!/usr/bin/env bash
# Coordination-dependency cleanup helper for /close-issue step 8.
#
# Walks the issue's comments looking for ```coord-dep-audit fenced blocks
# (the load-bearing artifact written by /sr-spec step 12 — bullet lines and
# free-form prose are NOT delete authority), unions all parent IDs across
# every well-formed block, deletes those blocked-by relations from Linear
# best-effort, classifies real failures vs. concurrent-UI removals via a
# post-delete re-fetch, and gates label removal on full delete success.
#
# Audit-comment format is documented in
# skills/sr-spec/scripts/coord_dep_scan.sh's header (single source of
# truth). Both /sr-spec finalize and ENG-281's /sr-start backstop emit
# this exact shape.
#
# Inputs:
#   ISSUE_ID                              — Linear issue id (required)
#   CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL  — workspace label to clear
#                                           on full success
#
# Exit codes:
#   0 — successful cleanup (label removed if it existed) OR no audit
#       blocks found (clean no-op).
#   1 — real failure: API error, page truncation, all-blocks-malformed,
#       workspace-label query failure, or one or more parents still
#       present after delete attempts. In every exit-1 path the coord-dep
#       label is KEPT so the operator sees that cleanup did not complete.

set -euo pipefail

# Idempotent re-source of the plugin libs the helper depends on.
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  # shellcheck source=/dev/null
  source "$CLAUDE_PLUGIN_ROOT/lib/linear.sh"
fi

if [[ -z "${ISSUE_ID:-}" ]]; then
  echo "cleanup_coord_dep: ISSUE_ID env var must be set" >&2
  exit 1
fi
if [[ -z "${CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL:-}" ]]; then
  echo "cleanup_coord_dep: CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL must be set" >&2
  exit 1
fi

# Try to remove the coord-dep workspace label from $ISSUE_ID. Branches on
# all three linear_label_exists return codes — collapsing rc=2 (query error
# / page truncation) into the rc=1 "absent" branch would let a transient
# Linear failure mask itself as a clean cleanup.
#   rc 0 — label exists; attempt remove (per-issue removal failure is
#          logged but not fatal — best-effort).
#   rc 1 — label genuinely absent in workspace; skip remove, success.
#   rc 2 — query error / pagination truncation; KEEP label, return 1 so
#          the caller exits non-zero. linear_label_exists prints its own
#          diagnostic on this path.
# Returns 0 on success or skip; 1 on query error.
_clear_coord_dep_label() {
  local label="$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL"
  local rc=0
  linear_label_exists "$label" || rc=$?
  case "$rc" in
    0)
      linear_remove_label "$ISSUE_ID" "$label" \
        || echo "cleanup_coord_dep: label removal failed — continuing" >&2
      ;;
    1)
      echo "cleanup_coord_dep: workspace label $label not present — skipping label remove" >&2
      ;;
    *)
      echo "cleanup_coord_dep: workspace label query failed (rc=$rc) — KEEPING coord-dep label" >&2
      return 1
      ;;
  esac
}

# 1. Query audit-block-bearing comments. body.contains filter narrows to
#    comments that mention the marker; per-block jq below treats the fenced
#    JSON block as the only delete authority. `linear issue comment list`
#    is NOT used: it truncates at ~50 with no cursor support (see
#    skills/prepare-for-review/SKILL.md).
comments="$(linear api --variable "issueId=$ISSUE_ID" <<'GRAPHQL' 2>&1
query($issueId: String!) {
  issue(id: $issueId) {
    comments(filter: { body: { contains: "coord-dep-audit" } }, first: 250) {
      pageInfo { hasNextPage }
      nodes { id body }
    }
  }
}
GRAPHQL
)" || {
  echo "cleanup_coord_dep: comment query failed for $ISSUE_ID — KEEPING coord-dep label" >&2
  exit 1
}

# Validate response shape — must have data.issue.comments.nodes.
if ! printf '%s' "$comments" | jq -e '.data.issue.comments.nodes' > /dev/null 2>&1; then
  echo "cleanup_coord_dep: unexpected GraphQL response shape for $ISSUE_ID — KEEPING coord-dep label" >&2
  exit 1
fi

has_next="$(printf '%s' "$comments" | jq -r '.data.issue.comments.pageInfo.hasNextPage // false')"
if [[ "$has_next" == "true" ]]; then
  echo "cleanup_coord_dep: $ISSUE_ID has more than 250 audit-bearing comments — silent truncation refused" >&2
  exit 1
fi

# 2. Extract fenced blocks per-comment, isolated awk per comment so an
#    unclosed fence in one comment can't leak flag=1 into the next.
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
comment_count=0

# Portable base64 decode: BSD (macOS) uses -D historically; GNU uses -d.
# Both flags are accepted on macOS Ventura+, but detect to handle older hosts.
if printf '' | base64 -D >/dev/null 2>&1; then
  _b64d() { base64 -D; }
else
  _b64d() { base64 -d; }
fi

while IFS= read -r body_b64; do
  [[ -n "$body_b64" ]] || continue
  comment_count=$((comment_count + 1))
  printf '%s' "$body_b64" | _b64d | awk -v dir="$tmpdir" -v c="$comment_count" '
    /^```coord-dep-audit$/{n++; out=sprintf("%s/c%05d-block-%05d.json", dir, c, n); flag=1; next}
    /^```$/{flag=0; next}
    flag{print > out}
  '
done < <(printf '%s' "$comments" | jq -r '.data.issue.comments.nodes[].body | @base64')

fenced_block_count="$(find "$tmpdir" -maxdepth 1 -name 'c*-block-*.json' -type f 2>/dev/null | wc -l | tr -d ' ')"

# Per-block jq with 2>/dev/null: a single malformed block must not
# suppress valid `parents` from other well-formed blocks. A `jq -s`
# over the concatenated stream is explicitly avoided because it would
# reject the whole stream on the first parse error.
parents="$(
  for f in "$tmpdir"/c*-block-*.json; do
    [[ -f "$f" ]] || continue
    jq -r '.parents[]?' "$f" 2>/dev/null || true
  done | sort -u
)"

# 3. Distinguish "no audit data" (clean fast path) from "malformed".
if [[ -z "$parents" ]]; then
  if [[ "$fenced_block_count" -gt 0 ]]; then
    echo "cleanup_coord_dep: $fenced_block_count audit block(s) found but yielded zero parsable parents — KEEPING coord-dep label" >&2
    exit 1
  fi
  # Truly no audit blocks. Clean fast path: clear the label if present.
  _clear_coord_dep_label || exit 1
  exit 0
fi

# 4. Best-effort delete. Linear's relation-delete returns the same exit
#    status for present-and-deleted, present-and-failed, and absent —
#    so don't classify per-call. Re-fetch blockers afterwards; any
#    marker-parent still present is a real failure. (Pre-delete snapshot
#    would misclassify a concurrent UI removal as a failure.)
for p in $parents; do
  linear issue relation delete "$ISSUE_ID" blocked-by "$p" 2>/dev/null || true
done

if ! final_blockers="$(linear_get_issue_blockers "$ISSUE_ID" | jq -r '.[].id' | sort -u)"; then
  echo "cleanup_coord_dep: post-delete linear_get_issue_blockers failed — KEEPING label conservatively" >&2
  exit 1
fi

real_failures=0
for p in $parents; do
  if printf '%s\n' "$final_blockers" | grep -qx "$p"; then
    echo "cleanup_coord_dep: $p still present after delete — real failure" >&2
    real_failures=$((real_failures + 1))
  fi
done

# 5. Label removal gated on full delete success. If any real failure,
#    keep the label so the operator can see cleanup is incomplete.
if [[ "$real_failures" -eq 0 ]]; then
  _clear_coord_dep_label || exit 1
  exit 0
else
  echo "cleanup_coord_dep: $real_failures edge(s) still present; coord-dep label kept" >&2
  exit 1
fi
