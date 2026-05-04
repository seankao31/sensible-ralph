#!/usr/bin/env bash
# close-issue stale-parent helpers.
# Sourced (not executed); do NOT call `set` or `exit` at top level.
#
# Dependencies (caller must source before invoking):
#   - lib/linear.sh (sr-start): linear_label_exists, linear_get_issue_blocks,
#     linear_comment, linear_add_label
#   - lib/branch_ancestry.sh (sr-start): is_branch_fresh_vs_sha,
#     list_commits_ahead, resolve_branch_for_issue
#   - $CLAUDE_PLUGIN_OPTION_STALE_PARENT_LABEL
#   - $CLAUDE_PLUGIN_OPTION_REVIEW_STATE
#
# Functions:
#   close_issue_label_stale_children       — public entry point (Step 6)
#   _close_issue_stale_label_and_comment   — module-private; comment+label one child

# Comment-first, label-second: the comment explains WHY the label was applied.
# If comment posting fails we skip the label (harmless state: no comment,
# no label). If the label application fails after a successful comment, the
# warning names that specific failure so the operator can apply the label
# manually — rather than being left guessing from a generic "label+comment
# failed" message. Returns:
#   0 — both succeeded (child is both commented and labeled)
#   1 — comment failed (nothing applied; safe to skip labeling)
#   2 — comment succeeded but label failed (partial: comment exists, label missing)
_close_issue_stale_label_and_comment() {
  local child_id="$1" child_branch="$2" parent_id="$3"
  local parent_pre_merge_sha="$4" parent_pre_merge_short="$5" parent_integration_short="$6"
  local commits count truncated body
  commits=$(list_commits_ahead "$parent_pre_merge_sha" "refs/heads/$child_branch") \
    || { printf 'list_commits_ahead failed for %s\n' "$child_id" >&2; return 1; }
  count=$(printf '%s\n' "$commits" | grep -c . || true)
  truncated=""
  if [ "$count" -gt 50 ]; then
    commits=$(printf '%s\n' "$commits" | head -50)
    truncated=$(printf '\n(%d more)' "$((count - 50))")
  fi

  # Base-branch-agnostic wording — close-issue doesn't know the project's
  # integration branch name. The child's reviewer can infer from the
  # parent issue's close comment or project convention.
  body=$(cat <<COMMENT
**Stale-parent check** — parent \`${parent_id}\` closed at \`${parent_integration_short}\`. Pre-merge branch tip was \`${parent_pre_merge_short}\`.

This branch (\`${child_branch}\`) does not have \`${parent_pre_merge_short}\` as an ancestor: \`${parent_id}\` received commits during review that this branch was not rebased onto, so the reviewer signed off on content against an older base.

Commits on the parent not present on this branch:

\`\`\`
${commits}${truncated}
\`\`\`

Recommended: rebase this branch onto the landed parent and re-review. If the diverging commits are content-equivalent to what was already reviewed (e.g. mechanical fixups, amended commit messages), dismiss the label manually. If this branch has its own In-Progress/In-Review descendants, rebasing here cascades to them.
COMMENT
)

  linear_comment "$child_id" "$body" || return 1
  linear_add_label "$child_id" "$CLAUDE_PLUGIN_OPTION_STALE_PARENT_LABEL" || return 2
}

# Step 6 entry point. Always returns 0 — labeling is observational, not a
# merge-safety gate; every failure path is a WARN entry, never an exit.
# Either SHA empty → silent no-op (defensive layer; the call site in
# close-issue/SKILL.md already gates on $INTEGRATION_SHA non-empty).
# Ancestry checks (is_branch_fresh_vs_sha, list_commits_ahead) consume the
# pre-merge SHA — that's the parent tip the reviewer signed off on, before
# close-branch's rebase rewrote commit IDs. The integration SHA is body-text
# only (the lead "closed at" line), never fed to ancestry helpers.
close_issue_label_stale_children() {
  local issue_id="$1"
  local parent_pre_merge_sha="$2"
  local parent_integration_sha="$3"

  if [ -z "$parent_pre_merge_sha" ] || [ -z "$parent_integration_sha" ]; then
    return 0
  fi

  local parent_pre_merge_short parent_integration_short
  # TODO(ENG-236): a malformed SHA in either positional arg would abort the
  # entire close-issue ritual under the caller's `set -e`. Out of scope
  # for this extraction; signposted for a future hardening lift.
  parent_pre_merge_short=$(git rev-parse --short "$parent_pre_merge_sha")
  parent_integration_short=$(git rev-parse --short "$parent_integration_sha")
  local WARN=()
  local stale_count=0
  # Working variables declared local here — the original inline body
  # did not need `local` because it ran in a transient shell context (no
  # function return). After extraction into a sourced function, omitting `local`
  # would silently overwrite same-named variables in the caller's shell on
  # every invocation.
  local label_rc blocks_json children child_id
  local resolve_rc child_branch child_slug fresh_rc apply_rc

  # Verify the workspace-scoped stale-parent label exists BEFORE touching any
  # children. Linear's `issue update --label` silently no-ops on a nonexistent
  # or team-scoped name, which would otherwise let Step 6 increment the
  # "labeled N children" counter against ghosts. sr-start's preflight
  # plumbs the same check; this skill doesn't run that preflight, so we gate
  # here once per close event.
  label_rc=0
  linear_label_exists "$CLAUDE_PLUGIN_OPTION_STALE_PARENT_LABEL" || label_rc=$?
  if [ "$label_rc" -ne 0 ]; then
    case "$label_rc" in
      1) WARN+=("workspace label $CLAUDE_PLUGIN_OPTION_STALE_PARENT_LABEL does not exist — skipping stale-parent check (see sr-start SKILL.md Prerequisites)") ;;
      *) WARN+=("could not verify workspace label $CLAUDE_PLUGIN_OPTION_STALE_PARENT_LABEL exists — skipping stale-parent check") ;;
    esac
    blocks_json='[]'
  else
    blocks_json=$(linear_get_issue_blocks "$issue_id") || {
      WARN+=("could not query outgoing blocks relations for $issue_id; skipping stale-parent check")
      blocks_json='[]'
    }
  fi

  # Walk children currently in the configured review state. `blocked-by`
  # descendants further down the chain (C → B → A) are not examined here — C
  # will be evaluated at B's close. One level per close event keeps the
  # propagation aligned with actual close events.
  #
  # Shape-guard the helper's output with the same pattern as Pre-flight §2.
  # A null .state or .id in any entry means Linear returned a relation whose
  # `relatedIssue` failed to resolve (schema drift, permission hide, deleted
  # target). Silently dropping such entries would miss genuinely stale
  # children; instead, stop here and let the operator investigate.
  children=$(printf '%s' "$blocks_json" | jq -r --arg review "$CLAUDE_PLUGIN_OPTION_REVIEW_STATE" '
    if type == "array" and all(.[]; has("id") and has("state") and .id != null and .state != null) then
      .[] | select(.state == $review) | .id
    else
      error("linear_get_issue_blocks returned unexpected JSON shape (null id/state)")
    end
  ') || {
    WARN+=("linear_get_issue_blocks returned malformed entries for $issue_id; skipping stale-parent check")
    children=""
  }

  # Redundant reset (already `local stale_count=0` above) — preserved verbatim
  # from the original inline body per ENG-236 AC#6. Do NOT remove.
  stale_count=0
  while IFS= read -r child_id; do
    [ -z "$child_id" ] && continue

    resolve_rc=0
    child_branch=$(resolve_branch_for_issue "$child_id" 2>/dev/null) || resolve_rc=$?
    if [ "$resolve_rc" -ne 0 ]; then
      child_slug=$(printf '%s' "$child_id" | tr '[:upper:]' '[:lower:]')
      case "$resolve_rc" in
        1) WARN+=("$child_id: no local branch matching ${child_slug}-* — cannot verify freshness (skipped)") ;;
        2) WARN+=("$child_id: multiple local branches match ${child_slug}-* — ambiguous, cannot verify freshness (skipped)") ;;
      esac
      continue
    fi

    # `|| rc=$?` captures the rc without triggering errexit in callers that
    # have it on — same pattern as preflight_labels.sh.
    fresh_rc=0
    is_branch_fresh_vs_sha "$parent_pre_merge_sha" "refs/heads/$child_branch" || fresh_rc=$?
    case "$fresh_rc" in
      0) ;;
      1) apply_rc=0
         _close_issue_stale_label_and_comment "$child_id" "$child_branch" "$issue_id" \
           "$parent_pre_merge_sha" "$parent_pre_merge_short" "$parent_integration_short" \
           || apply_rc=$?
         case "$apply_rc" in
           0) stale_count=$((stale_count + 1)) ;;
           1) WARN+=("$child_id: stale parent detected but comment-post failed (no label applied)") ;;
           2) WARN+=("$child_id: stale parent detected; comment posted but label application failed (apply $CLAUDE_PLUGIN_OPTION_STALE_PARENT_LABEL manually)") ;;
         esac
         ;;
      2) WARN+=("$child_id ($child_branch): ancestry lookup failed")
         ;;
    esac
  done <<< "$children"

  [ "$stale_count" -gt 0 ] && WARN+=("applied $CLAUDE_PLUGIN_OPTION_STALE_PARENT_LABEL label to $stale_count child(ren)")

  # Emit accumulated notes immediately so Linear mutations performed here are
  # always visible to the operator, even if a later step aborts the ritual.
  if [ "${#WARN[@]}" -gt 0 ]; then
    printf '\n⚠️  Step 6 notes:\n'
    printf '  - %s\n' "${WARN[@]}"
  fi

  return 0
}
