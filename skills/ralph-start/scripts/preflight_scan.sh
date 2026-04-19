#!/usr/bin/env bash
set -euo pipefail

# Pre-flight sanity scan per Decision 6: canceled/duplicate/stuck blockers,
# missing/trivial PRD. Scans all Approved issues and reports anomalies.
# Exits non-zero if any anomalies found so the operator can fix before dispatch.

# shellcheck source=lib/linear.sh
source "$(dirname "$0")/lib/linear.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Check whether a blocker state counts as "resolved" (In Review or Done).
# Returns 0 (true) if resolved, 1 (false) otherwise.
_blocker_is_resolved() {
  local state="$1"
  [[ "$state" == "In Review" || "$state" == "Done" ]]
}

# Fetch the non-whitespace character count for an issue's description.
# Calls: linear issue view <id> --json --no-comments
_desc_nonws_chars() {
  local issue_id="$1"
  local view_json desc
  view_json="$(linear issue view "$issue_id" --json --no-comments)"
  desc="$(printf '%s' "$view_json" | jq -r '.description // ""')"
  printf '%s' "$desc" | tr -cd '[:graph:]' | wc -c | tr -d ' '
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
  # A blocker is Approved (not In Review/Done) AND its own blockers are not all In Review/Done.
  # This means the chain won't dispatch overnight.
  blocker_count="$(printf '%s' "$blockers_json" | jq 'length')"
  for (( i = 0; i < blocker_count; i++ )); do
    b_state="$(printf '%s' "$blockers_json" | jq -r ".[$i].state")"
    b_id="$(printf '%s' "$blockers_json" | jq -r ".[$i].id")"

    # Only Approved blockers can be stuck (In Review/Done are resolved)
    if _blocker_is_resolved "$b_state"; then
      continue
    fi
    # Blocker is not resolved — check if its own blockers are all In Review/Done
    b_own_blockers="$(linear_get_issue_blockers "$b_id")"
    b_own_count="$(printf '%s' "$b_own_blockers" | jq 'length')"
    stuck=0
    for (( j = 0; j < b_own_count; j++ )); do
      own_state="$(printf '%s' "$b_own_blockers" | jq -r ".[$j].state")"
      if ! _blocker_is_resolved "$own_state"; then
        stuck=1
        break
      fi
    done
    if [[ "$stuck" -eq 1 ]]; then
      anomalies+=("[WARN] $issue_id: stuck blocker chain — blocker $b_id is Approved with unresolved blockers of its own")
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
