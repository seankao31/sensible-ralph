#!/usr/bin/env bash
set -euo pipefail

# DAG base-branch selection (Decision 7).
# Input:  $1 = issue ID; env vars CLAUDE_PLUGIN_OPTION_REVIEW_STATE,
#              CLAUDE_PLUGIN_OPTION_APPROVED_STATE from the plugin harness;
#              SENSIBLE_RALPH_DEFAULT_BASE_BRANCH from lib/scope.sh (auto-sourced below).
# Output: "<SENSIBLE_RALPH_DEFAULT_BASE_BRANCH>" | "<branch>" | "INTEGRATION <branch1> <branch2> ..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

# shellcheck source=../../../lib/defaults.sh
source "$PLUGIN_ROOT/lib/defaults.sh"

# Auto-source scope unless the load marker matches THIS invocation's repo +
# scope-file content. See orchestrator.sh for rationale.
RESOLVED_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || RESOLVED_REPO_ROOT=""
RESOLVED_SCOPE_HASH=""
if [[ -n "$RESOLVED_REPO_ROOT" && -f "$RESOLVED_REPO_ROOT/.sensible-ralph.json" ]]; then
  RESOLVED_SCOPE_HASH="$(shasum -a 1 < "$RESOLVED_REPO_ROOT/.sensible-ralph.json" | awk '{print $1}')"
fi
# shellcheck source=../../../lib/linear.sh
source "$PLUGIN_ROOT/lib/linear.sh"

EXPECTED_SCOPE_LOADED="${RESOLVED_REPO_ROOT}|${RESOLVED_SCOPE_HASH}"
if [[ "${SENSIBLE_RALPH_SCOPE_LOADED:-}" != "$EXPECTED_SCOPE_LOADED" ]]; then
  # shellcheck source=../../../lib/scope.sh
  source "$PLUGIN_ROOT/lib/scope.sh"
fi

issue_id="$1"

blockers_json="$(linear_get_issue_blockers "$issue_id")"

# Fail fast if any in-review blocker has no branch name. Match BOTH JSON null
# (the new GraphQL path emits real null for missing branchName) AND the string
# "null" (defensive — historical text-parsing flow stringified missing values).
null_branches="$(printf '%s' "$blockers_json" | jq -r \
  --arg state "$CLAUDE_PLUGIN_OPTION_REVIEW_STATE" \
  '.[] | select(.state == $state) | select(.branch == null or .branch == "null" or .branch == "") | .id')"
if [[ -n "$null_branches" ]]; then
  printf 'dag_base: in-review blocker(s) have no branch name: %s\n' "$null_branches" >&2
  exit 1
fi

# Extract branches of blockers whose state matches CLAUDE_PLUGIN_OPTION_REVIEW_STATE
review_branches="$(printf '%s' "$blockers_json" | jq -r \
  --arg state "$CLAUDE_PLUGIN_OPTION_REVIEW_STATE" \
  '.[] | select(.state == $state) | .branch')"

# Count how many In Review blockers there are
review_count="$(printf '%s' "$review_branches" | grep -c . || true)"

if [[ $review_count -eq 0 ]]; then
  printf '%s\n' "$SENSIBLE_RALPH_DEFAULT_BASE_BRANCH"
elif [[ $review_count -eq 1 ]]; then
  printf '%s\n' "$review_branches"
else
  # Join branch names with spaces for INTEGRATION output
  branches_space="$(printf '%s' "$review_branches" | tr '\n' ' ' | sed 's/ $//')"
  printf 'INTEGRATION %s\n' "$branches_space"
fi
