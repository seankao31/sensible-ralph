#!/usr/bin/env bash
# Linear CLI wrapper functions.
# This file is sourced (not executed); do NOT call `set` at the top level or `exit`.
#
# Callers must source lib/config.sh first to export:
#   RALPH_PROJECT, RALPH_APPROVED_STATE, RALPH_FAILED_LABEL
#
# Functions:
#   linear_list_approved_issues  — list Approved issue IDs (one per line)
#   linear_get_issue_blockers    — get blockers as JSON array
#   linear_get_issue_branch      — get Linear-generated branch name for an issue
#   linear_set_state             — move an issue to a named workflow state
#   linear_add_label             — add a label additively (preserves existing labels)
#   linear_comment               — post a comment on an issue

# List issue IDs in the configured project with state name matching
# $RALPH_APPROVED_STATE, excluding any issues labeled $RALPH_FAILED_LABEL.
# Outputs one issue ID per line.
linear_list_approved_issues() {
  local raw
  raw="$(linear issue query --project "$RALPH_PROJECT" --all-teams --limit 0 --json)" || {
    printf 'linear_list_approved_issues: failed to query issues\n' >&2
    return 1
  }

  printf '%s' "$raw" | jq -r \
    --arg state "$RALPH_APPROVED_STATE" \
    --arg failed_label "$RALPH_FAILED_LABEL" \
    '.nodes[]
     | select(.state.name == $state)
     | select(
         (.labels.nodes | map(.name) | index($failed_label)) == null
       )
     | .identifier'
}

# Get blockers for an issue.
# Outputs a JSON array: [{"id":"ENG-X","state":"Done","branch":"eng-x-slug"}, ...]
# Issues with no blocked-by relations output: [].
#
# Uses `linear api` to query the GraphQL endpoint directly. The CLI's
# `issue relation list` subcommand has no --json flag (v2.0.0), so the
# previous text-parsing approach was brittle to CLI format changes.
# `inverseRelations` returns relations pointing AT this issue; we filter to
# type=="blocks" client-side via jq, since the IssueRelationConnection has no
# server-side filter parameter.
#
# Pagination: requests first: 250 (well above realistic blocker counts) and
# checks pageInfo.hasNextPage. If truncation occurred, returns non-zero with
# a clear error — silent truncation would let downstream consumers (preflight,
# build_queue, dag_base) work from an incomplete dependency set and misjudge
# stuck-chains, base-branch selection, and taint propagation. 250 blockers on
# a single issue is implausible in practice; failing loud is the right
# default for the unrealistic case.
linear_get_issue_blockers() {
  local issue_id="$1"
  local raw
  raw="$(linear api --variable "issueId=$issue_id" <<'GRAPHQL'
query($issueId: String!) {
  issue(id: $issueId) {
    inverseRelations(first: 250) {
      pageInfo { hasNextPage }
      nodes {
        type
        issue {
          identifier
          branchName
          state { name }
        }
      }
    }
  }
}
GRAPHQL
)" || { printf 'linear_get_issue_blockers: failed to query relations for %s\n' "$issue_id" >&2; return 1; }

  local has_next_page
  has_next_page="$(printf '%s' "$raw" | jq -r '.data.issue.inverseRelations.pageInfo.hasNextPage')"
  if [[ "$has_next_page" == "true" ]]; then
    printf 'linear_get_issue_blockers: %s has more than 250 inverse relations — silent truncation refused. Investigate before re-running.\n' "$issue_id" >&2
    return 1
  fi

  printf '%s' "$raw" | jq -c '
    [ .data.issue.inverseRelations.nodes[]
      | select(.type == "blocks")
      | { id: .issue.identifier, state: .issue.state.name, branch: .issue.branchName }
    ]
  '
}

# Get the Linear-generated branch name for an issue.
# Outputs: eng-XXX-slug-from-title
linear_get_issue_branch() {
  local issue_id="$1"
  local view_json
  view_json="$(linear issue view "$issue_id" --json --no-comments)" \
    || { printf 'linear_get_issue_branch: failed to view %s\n' "$issue_id" >&2; return 1; }
  printf '%s' "$view_json" | jq -r '.branchName'
}

# Move an issue to a named workflow state.
linear_set_state() {
  local issue_id="$1"
  local state_name="$2"
  linear issue update "$issue_id" --state "$state_name" \
    || { printf 'linear_set_state: failed to update state for %s\n' "$issue_id" >&2; return 1; }
}

# Add a label to an issue additively (preserves existing labels).
# Note: `linear issue update --label` REPLACES all labels, so we must
# fetch the current labels first and re-apply them along with the new one.
linear_add_label() {
  local issue_id="$1"
  local new_label="$2"

  # Fetch current labels
  local view_json
  view_json="$(linear issue view "$issue_id" --json --no-comments)" \
    || { printf 'linear_add_label: failed to view %s\n' "$issue_id" >&2; return 1; }

  local existing_labels=()
  while IFS= read -r lbl; do
    [[ -n "$lbl" ]] && existing_labels+=("$lbl")
  done < <(printf '%s' "$view_json" | jq -r '.labels.nodes[].name')

  # Build --label flags for all existing labels (skipping new_label to avoid duplicates) + new label
  local label_args=()
  local lbl
  for lbl in "${existing_labels[@]}"; do
    [[ "$lbl" == "$new_label" ]] && continue
    label_args+=(--label "$lbl")
  done
  label_args+=(--label "$new_label")

  linear issue update "$issue_id" "${label_args[@]}" \
    || { printf 'linear_add_label: failed to update labels for %s\n' "$issue_id" >&2; return 1; }
}

# Post a comment on an issue.
linear_comment() {
  local issue_id="$1"
  local body="$2"
  linear issue comment add "$issue_id" --body "$body" \
    || { printf 'linear_comment: failed to comment on %s\n' "$issue_id" >&2; return 1; }
}
