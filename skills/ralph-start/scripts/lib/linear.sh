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
  raw="$(linear issue query --project "$RALPH_PROJECT" --all-teams --state unstarted --json)"

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
# Issues with no blocked-by relations output: []
linear_get_issue_blockers() {
  local issue_id="$1"

  # Get the relations text output; extract "blocked-by" entries from the Incoming section
  local relations_text
  relations_text="$(linear issue relation list "$issue_id")"

  # Parse blocker IDs: find lines in the Incoming section that say "blocked-by"
  # Format: "  ENG-XXX blocked-by ENG-YYY: Title"
  # The blocker is the 4th token (index 3) — "ENG-XXX blocked-by ENG-YYY"
  #                                                     ^token0  ^token1  ^token2  ^token3...
  # Wait: "  ENG-XXX blocked-by ENG-YYY" → after trimming leading spaces:
  # token0=ENG-XXX, token1=blocked-by, token2=ENG-YYY:, token3=Title...
  # Actually the issue_id appears as token0, "blocked-by" as token1, blocker as token2 (with colon)
  local blocker_ids=()
  local in_incoming=0
  while IFS= read -r line; do
    if [[ "$line" == "Incoming:"* ]]; then
      in_incoming=1
      continue
    fi
    # Any non-indented line (or blank) after Incoming: ends the section
    if [[ $in_incoming -eq 1 ]]; then
      if [[ -z "$line" || "$line" != "  "* ]]; then
        in_incoming=0
        continue
      fi
      # Line is indented: "  ENG-XXX blocked-by ENG-YYY: Title"
      read -r -a tokens <<< "$line"
      # tokens[0]=ENG-XXX, tokens[1]=blocked-by, tokens[2]=ENG-YYY:
      if [[ "${tokens[1]:-}" == "blocked-by" ]]; then
        # Strip trailing colon from blocker id
        local blocker_id="${tokens[2]%:}"
        blocker_ids+=("$blocker_id")
      fi
    fi
  done <<< "$relations_text"

  if [[ ${#blocker_ids[@]} -eq 0 ]]; then
    printf '[]'
    return 0
  fi

  # Fetch state and branch for each blocker, build JSON array
  local json_entries=()
  local bid view_json state branch
  for bid in "${blocker_ids[@]}"; do
    view_json="$(linear issue view "$bid" --json --no-comments)"
    state="$(printf '%s' "$view_json" | jq -r '.state.name')"
    branch="$(printf '%s' "$view_json" | jq -r '.branchName')"
    json_entries+=("$(printf '{"id": "%s", "state": "%s", "branch": "%s"}' "$bid" "$state" "$branch")")
  done

  # Join entries with comma into a JSON array
  local joined
  printf -v joined '%s, ' "${json_entries[@]}"
  joined="${joined%, }"  # strip trailing ", "
  printf '[%s]' "$joined"
}

# Get the Linear-generated branch name for an issue.
# Outputs: eng-XXX-slug-from-title
linear_get_issue_branch() {
  local issue_id="$1"
  linear issue view "$issue_id" --json --no-comments | jq -r '.branchName'
}

# Move an issue to a named workflow state.
linear_set_state() {
  local issue_id="$1"
  local state_name="$2"
  linear issue update "$issue_id" --state "$state_name"
}

# Add a label to an issue additively (preserves existing labels).
# Note: `linear issue update --label` REPLACES all labels, so we must
# fetch the current labels first and re-apply them along with the new one.
linear_add_label() {
  local issue_id="$1"
  local new_label="$2"

  # Fetch current labels
  local view_json
  view_json="$(linear issue view "$issue_id" --json --no-comments)"

  local existing_labels=()
  while IFS= read -r lbl; do
    [[ -n "$lbl" ]] && existing_labels+=("$lbl")
  done < <(printf '%s' "$view_json" | jq -r '.labels.nodes[].name')

  # Build --label flags for all existing + new label
  local label_args=()
  local lbl
  for lbl in "${existing_labels[@]}"; do
    label_args+=(--label "$lbl")
  done
  label_args+=(--label "$new_label")

  linear issue update "$issue_id" "${label_args[@]}"
}

# Post a comment on an issue.
linear_comment() {
  local issue_id="$1"
  local body="$2"
  linear issue comment add "$issue_id" --body "$body"
}
