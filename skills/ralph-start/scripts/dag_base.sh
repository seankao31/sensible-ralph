#!/usr/bin/env bash
set -euo pipefail

# DAG base-branch selection (Decision 7).
# Input:  $1 = issue ID; env vars RALPH_REVIEW_STATE, RALPH_APPROVED_STATE from config.sh.
# Output: "main" | "<branch>" | "INTEGRATION <branch1> <branch2> ..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Auto-source config if not already loaded. See orchestrator.sh for rationale.
if [[ -z "${RALPH_CONFIG_LOADED:-}" ]]; then
  CONFIG_FILE="${RALPH_CONFIG:-$SCRIPT_DIR/../config.json}"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "dag_base: config not found at $CONFIG_FILE — set RALPH_CONFIG or create config.json" >&2
    exit 1
  fi
  # shellcheck source=lib/config.sh
  source "$SCRIPT_DIR/lib/config.sh" "$CONFIG_FILE"
fi

# shellcheck source=lib/linear.sh
source "$SCRIPT_DIR/lib/linear.sh"

issue_id="$1"

blockers_json="$(linear_get_issue_blockers "$issue_id")"

# Fail fast if any in-review blocker has no branch name
null_branches="$(printf '%s' "$blockers_json" | jq -r \
  --arg state "$RALPH_REVIEW_STATE" \
  '.[] | select(.state == $state) | select(.branch == "null" or .branch == "") | .id')"
if [[ -n "$null_branches" ]]; then
  printf 'dag_base: in-review blocker(s) have no branch name: %s\n' "$null_branches" >&2
  exit 1
fi

# Extract branches of blockers whose state matches RALPH_REVIEW_STATE
review_branches="$(printf '%s' "$blockers_json" | jq -r \
  --arg state "$RALPH_REVIEW_STATE" \
  '.[] | select(.state == $state) | .branch')"

# Count how many In Review blockers there are
review_count="$(printf '%s' "$review_branches" | grep -c . || true)"

if [[ $review_count -eq 0 ]]; then
  printf 'main\n'
elif [[ $review_count -eq 1 ]]; then
  printf '%s\n' "$review_branches"
else
  # Join branch names with spaces for INTEGRATION output
  branches_space="$(printf '%s' "$review_branches" | tr '\n' ' ' | sed 's/ $//')"
  printf 'INTEGRATION %s\n' "$branches_space"
fi
