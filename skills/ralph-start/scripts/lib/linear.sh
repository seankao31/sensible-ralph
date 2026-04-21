#!/usr/bin/env bash
# Linear CLI wrapper functions.
# This file is sourced (not executed); do NOT call `set` at the top level or `exit`.
#
# Callers must source lib/config.sh first to export:
#   RALPH_PROJECTS (newline-joined), RALPH_APPROVED_STATE, RALPH_FAILED_LABEL
#
# Functions:
#   linear_list_approved_issues     — list Approved issue IDs (one per line)
#   linear_list_initiative_projects — expand an initiative name to its project names
#   linear_get_issue_blockers       — get blockers as JSON array
#   linear_get_issue_branch         — get Linear-generated branch name for an issue
#   linear_set_state                — move an issue to a named workflow state
#   linear_add_label                — add a label additively (preserves existing labels)
#   linear_comment                  — post a comment on an issue

# List issue IDs across the configured projects ($RALPH_PROJECTS, newline-
# joined) with state name matching $RALPH_APPROVED_STATE, excluding issues
# labeled $RALPH_FAILED_LABEL. Outputs one issue ID per line.
#
# Makes one `linear issue query` call per project and concatenates results.
# Preserved over a single GraphQL query with a project-list filter because
# the CLI already handles workspace + pagination semantics; duplicating that
# in raw GraphQL adds drift risk for a modest round-trip saving (projects
# per repo are few — typically 1-3).
linear_list_approved_issues() {
  local project raw
  while IFS= read -r project; do
    [[ -z "$project" ]] && continue
    raw="$(linear issue query --project "$project" --all-teams --limit 0 --json)" || {
      printf 'linear_list_approved_issues: failed to query project %q\n' "$project" >&2
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
  done <<< "$RALPH_PROJECTS"
}

# Expand an initiative name to the list of its member project names.
# Outputs: one project name per line (newline-joined).
#
# Used by config.sh when .ralph.json carries `initiative: "..."` instead of
# an explicit `projects` list. `linear issue query --initiative` does not
# exist (CLI v2.0.0), so the resolution path is a GraphQL lookup via
# `linear api`.
#
# Fails (non-zero) with a clear message for:
#   - zero matching initiatives (misspelled name, etc.)
#   - multiple matching initiatives (name isn't unique — ambiguous scope)
#   - projects page truncated at first: 50 (silent truncation refused for
#     the same reason as linear_get_issue_blockers: downstream consumers
#     would work from an incomplete scope)
linear_list_initiative_projects() {
  local initiative_name="$1"
  local raw
  raw="$(linear api --variable "initiativeName=$initiative_name" <<'GRAPHQL'
query($initiativeName: String!) {
  initiatives(filter: { name: { eq: $initiativeName } }, first: 2) {
    nodes {
      name
      projects(first: 50) {
        pageInfo { hasNextPage }
        nodes { name }
      }
    }
  }
}
GRAPHQL
)" || {
    printf 'linear_list_initiative_projects: failed to query initiative %q\n' "$initiative_name" >&2
    return 1
  }

  local match_count
  match_count="$(printf '%s' "$raw" | jq '.data.initiatives.nodes | length')"
  if [[ "$match_count" -eq 0 ]]; then
    printf 'linear_list_initiative_projects: no initiative named %q\n' "$initiative_name" >&2
    return 1
  fi
  if [[ "$match_count" -gt 1 ]]; then
    printf 'linear_list_initiative_projects: multiple initiatives matched %q — rename one for uniqueness\n' "$initiative_name" >&2
    return 1
  fi

  local has_next
  has_next="$(printf '%s' "$raw" | jq -r '.data.initiatives.nodes[0].projects.pageInfo.hasNextPage')"
  if [[ "$has_next" == "true" ]]; then
    printf 'linear_list_initiative_projects: initiative %q has more than 50 projects — silent truncation refused\n' "$initiative_name" >&2
    return 1
  fi

  printf '%s' "$raw" | jq -r '.data.initiatives.nodes[0].projects.nodes[].name'
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
