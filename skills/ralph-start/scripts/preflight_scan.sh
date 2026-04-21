#!/usr/bin/env bash
set -euo pipefail

# Pre-flight sanity scan per Decision 6: canceled/duplicate/stuck blockers,
# missing/trivial PRD. Scans all Approved issues and reports anomalies.
# Exits non-zero if any anomalies found so the operator can fix before dispatch.
#
# Requires RALPH_PROJECTS, RALPH_APPROVED_STATE, RALPH_FAILED_LABEL,
# RALPH_REVIEW_STATE, RALPH_DONE_STATE exported (source lib/config.sh first).
#
# Performance: makes O(M * K) Linear CLI calls where M = number of Approved issues,
# K = average blocker count (plus recursive calls for stuck-chain check).
# Suitable for queues up to ~20 issues; expect 30-120s for larger queues.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Auto-source config unless the load marker matches THIS script's expected
# config path. See orchestrator.sh for rationale.
CONFIG_FILE="${RALPH_CONFIG:-$SCRIPT_DIR/../config.json}"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "preflight_scan: config not found at $CONFIG_FILE — set RALPH_CONFIG or create config.json" >&2
  exit 1
fi
RESOLVED_CONFIG="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"
RESOLVED_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || RESOLVED_REPO_ROOT=""
RESOLVED_SCOPE_HASH=""
if [[ -n "$RESOLVED_REPO_ROOT" && -f "$RESOLVED_REPO_ROOT/.ralph.json" ]]; then
  RESOLVED_SCOPE_HASH="$(shasum -a 1 < "$RESOLVED_REPO_ROOT/.ralph.json" | awk '{print $1}')"
fi
EXPECTED_LOADED_TUPLE="${RESOLVED_CONFIG}|${RESOLVED_REPO_ROOT}|${RESOLVED_SCOPE_HASH}"
if [[ "${RALPH_CONFIG_LOADED:-}" != "$EXPECTED_LOADED_TUPLE" ]]; then
  # shellcheck source=lib/config.sh
  source "$SCRIPT_DIR/lib/config.sh" "$CONFIG_FILE"
fi

# shellcheck source=lib/linear.sh
source "$SCRIPT_DIR/lib/linear.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Check whether a blocker state counts as "resolved" (in review or done).
# Returns 0 (true) if resolved, 1 (false) otherwise.
_blocker_is_resolved() {
  local state="$1"
  [[ "$state" == "$RALPH_REVIEW_STATE" || "$state" == "$RALPH_DONE_STATE" ]]
}

# Check whether a project name (exact match, whole line) is in RALPH_PROJECTS.
# Returns 0 if in scope, 1 otherwise. Pure bash — RALPH_PROJECTS values can
# contain spaces ("Agent Config"), so substring match is unsafe.
_project_in_scope() {
  local needle="$1" line
  while IFS= read -r line; do
    [[ "$line" == "$needle" ]] && return 0
  done <<< "$RALPH_PROJECTS"
  return 1
}

# Recursive check: returns 0 if every blocker reachable from $issue_id can
# clear in this orchestrator run, 1 if any blocker is in a non-runnable state
# (Todo, In Progress, etc.) or the chain contains a cycle.
#
# A blocker is "runnable in this run" iff it's already resolved (Done /
# In Review) OR it's Approved AND in this run's approved set
# (_PREFLIGHT_APPROVED_SET, set in main below) AND its own blockers are
# recursively runnable. An Approved blocker that's NOT in the run's queue
# (ralph-failed-labeled, in another project, etc.) cannot clear overnight
# and makes the chain stuck — without this membership check, a blocker that
# state-look like Approved would appear runnable when in reality the
# orchestrator will never dispatch it.
#
# Cycle detection uses a visited list. Cycles report stuck (return 1).
# Recursion depth is bounded by the longest cycle-free path; Linear API
# calls dominate runtime.
_chain_runnable() {
  local issue_id="$1"
  shift
  local visited=("$@")

  local v
  for v in "${visited[@]}"; do
    [[ "$v" == "$issue_id" ]] && return 1
  done
  visited+=("$issue_id")

  local blockers_json
  blockers_json="$(linear_get_issue_blockers "$issue_id")" || return 1
  local count
  count="$(printf '%s' "$blockers_json" | jq 'length')"

  local i b_state b_id
  for (( i = 0; i < count; i++ )); do
    b_state="$(printf '%s' "$blockers_json" | jq -r ".[$i].state")"
    b_id="$(printf '%s' "$blockers_json" | jq -r ".[$i].id")"
    if _blocker_is_resolved "$b_state"; then
      continue
    fi
    if [[ "$b_state" == "$RALPH_APPROVED_STATE" ]]; then
      if [[ "${_PREFLIGHT_APPROVED_SET:-}" != *" $b_id "* ]]; then
        return 1
      fi
      _chain_runnable "$b_id" "${visited[@]}" || return 1
      continue
    fi
    return 1
  done
  return 0
}

# Fetch the non-whitespace character count for an issue's description.
# Calls: linear issue view <id> --json --no-comments
_desc_nonws_chars() {
  local issue_id="$1"
  local view_json desc stripped
  view_json="$(linear issue view "$issue_id" --json --no-comments)"
  desc="$(printf '%s' "$view_json" | jq -r '.description // ""')"
  stripped="${desc//[[:space:]]/}"
  printf '%d' "${#stripped}"
}

# ---------------------------------------------------------------------------
# Main scan logic
# ---------------------------------------------------------------------------

anomalies=()

approved_ids="$(linear_list_approved_issues)"

if [[ -z "$approved_ids" ]]; then
  printf 'preflight: all clear\n'
  exit 0
fi

# Membership-test fixture for the approved set (space-delimited with leading
# and trailing space so substring match `*" $id "*` works for any id).
# Read by _chain_runnable to verify Approved blockers are actually queueable
# in this run.
_PREFLIGHT_APPROVED_SET=" $(printf '%s' "$approved_ids" | tr '\n' ' ') "

while IFS= read -r issue_id; do
  [[ -z "$issue_id" ]] && continue

  # Fetch blockers for this issue
  blockers_json="$(linear_get_issue_blockers "$issue_id")"

  # --- Check 1: Canceled blocker ---
  canceled_count="$(printf '%s' "$blockers_json" | jq '[.[] | select(.state == "Canceled")] | length')"
  if [[ "$canceled_count" -gt 0 ]]; then
    anomalies+=("[WARN] $issue_id: has $canceled_count canceled blocker(s) — issue can never become unblocked")
  fi

  # --- Check 1b: Duplicate-state blocker ---
  duplicate_state_count="$(printf '%s' "$blockers_json" | jq '[.[] | select(.state == "Duplicate")] | length')"
  if [[ "$duplicate_state_count" -gt 0 ]]; then
    anomalies+=("[WARN] $issue_id: has $duplicate_state_count blocker(s) in Duplicate state — issue can never become unblocked")
  fi

  # --- Check 2: Duplicate blocker ---
  dupe_count="$(printf '%s' "$blockers_json" | jq '
    group_by(.id)
    | map(select(length > 1))
    | length
  ')"
  if [[ "$dupe_count" -gt 0 ]]; then
    anomalies+=("[WARN] $issue_id: has duplicate blocker ID(s) in its blocked-by list")
  fi

  # --- Check 3: Stuck blocker chain ---
  # An Approved blocker is stuck if either:
  #   - it's not in this run's approved set (not queueable here — ralph-failed
  #     labeled, in another project, etc.); or
  #   - its dependency chain has a blocker in a non-runnable state.
  # Recurses via _chain_runnable so deeper chains where the deepest issue is
  # already resolvable are correctly classified as not stuck.
  blocker_count="$(printf '%s' "$blockers_json" | jq 'length')"
  for (( i = 0; i < blocker_count; i++ )); do
    b_state="$(printf '%s' "$blockers_json" | jq -r ".[$i].state")"
    b_id="$(printf '%s' "$blockers_json" | jq -r ".[$i].id")"

    # Only Approved blockers can be stuck — In Progress/Todo etc. are reported by
    # other anomaly checks (or simply not orchestrator-dispatchable). Resolved
    # blockers (Done/In Review) trivially can't be stuck.
    if [[ "$b_state" != "$RALPH_APPROVED_STATE" ]]; then
      continue
    fi
    if [[ "$_PREFLIGHT_APPROVED_SET" != *" $b_id "* ]]; then
      b_project="$(printf '%s' "$blockers_json" | jq -r ".[$i].project")"
      if _project_in_scope "$b_project"; then
        anomalies+=("[WARN] $issue_id: stuck blocker chain — blocker $b_id is Approved in project '$b_project' (in scope) but not in this run's queue (likely ralph-failed-labeled)")
      else
        anomalies+=("[WARN] $issue_id: out-of-scope blocker — blocker $b_id is in project '$b_project', outside this run's scope. Add the project to .ralph.json or resolve the blocker relationship.")
      fi
      continue
    fi
    if ! _chain_runnable "$b_id" "$issue_id"; then
      anomalies+=("[WARN] $issue_id: stuck blocker chain — blocker $b_id is Approved with unrunnable transitive blockers")
    fi
  done

  # --- Check 4: Missing/trivial PRD ---
  desc_chars="$(_desc_nonws_chars "$issue_id")"
  if [[ "$desc_chars" -lt 200 ]]; then
    anomalies+=("[WARN] $issue_id: missing/trivial PRD — only $desc_chars non-whitespace character(s) in description (need >= 200)")
  fi

done <<< "$approved_ids"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [[ "${#anomalies[@]}" -eq 0 ]]; then
  printf 'preflight: all clear\n'
  exit 0
fi

for anomaly in "${anomalies[@]}"; do
  printf '%s\n' "$anomaly"
done
printf 'preflight: %d anomaly(ies) found\n' "${#anomalies[@]}"
exit 1
