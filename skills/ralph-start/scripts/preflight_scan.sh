#!/usr/bin/env bash
set -euo pipefail

# Pre-flight sanity scan per Decision 6: canceled/duplicate/stuck blockers,
# missing/trivial PRD. Scans all Approved issues and reports anomalies.
# Exits non-zero if any anomalies found so the operator can fix before dispatch.
#
# Requires RALPH_PROJECT, RALPH_APPROVED_STATE, RALPH_FAILED_LABEL,
# RALPH_REVIEW_STATE, RALPH_DONE_STATE exported (source lib/config.sh first).
#
# Performance: makes O(M * K) Linear CLI calls where M = number of Approved issues,
# K = average blocker count (plus recursive calls for stuck-chain check).
# Suitable for queues up to ~20 issues; expect 30-120s for larger queues.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Auto-source config if not already loaded. See orchestrator.sh for rationale.
if [[ -z "${RALPH_CONFIG_LOADED:-}" ]]; then
  CONFIG_FILE="${RALPH_CONFIG:-$SCRIPT_DIR/../config.json}"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "preflight_scan: config not found at $CONFIG_FILE — set RALPH_CONFIG or create config.json" >&2
    exit 1
  fi
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

# Recursive check: returns 0 if every blocker reachable from $issue_id can
# clear in this orchestrator run, 1 if any blocker is in a non-runnable state
# (Todo, In Progress, etc.) or the chain contains a cycle.
#
# A blocker is "runnable in this run" iff it's already resolved (Done /
# In Review) OR it's Approved AND its own blockers are recursively runnable.
# The orchestrator only dispatches Approved issues, so blockers in any other
# state (Triage, Backlog, Todo, In Progress, Canceled, Duplicate) will not
# clear overnight and the chain is stuck.
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
  # An Approved blocker is stuck if its dependency chain cannot clear overnight.
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
