#!/usr/bin/env bash
set -euo pipefail

# Build the dispatch queue: list pickup-ready Approved issues, sort
# topologically by blocked-by relations with priority as the tiebreaker,
# and print the ordered issue IDs (one per line) to stdout.
#
# Usage:
#   scripts/build_queue.sh > ordered_queue.txt
#
# An issue is pickup-ready only if:
#   - state == $RALPH_APPROVED_STATE
#   - no $RALPH_FAILED_LABEL label (filtered by linear_list_approved_issues)
#   - every blocked-by relation is in {$RALPH_DONE_STATE, $RALPH_REVIEW_STATE}
#
# Issues with any blocker in another state are skipped (not yet pickup-ready)
# and a warning is emitted to stderr.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Auto-source config unless the load marker matches THIS script's expected
# config path. See orchestrator.sh for rationale.
CONFIG_FILE="${RALPH_CONFIG:-$SCRIPT_DIR/../config.json}"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "build_queue: config not found at $CONFIG_FILE — set RALPH_CONFIG or create config.json" >&2
  exit 1
fi
RESOLVED_CONFIG="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"
RESOLVED_REPO_ROOT="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || RESOLVED_REPO_ROOT=""
[[ -n "$RESOLVED_REPO_ROOT" ]] && RESOLVED_REPO_ROOT="$(dirname "$RESOLVED_REPO_ROOT")"
EXPECTED_LOADED_TUPLE="${RESOLVED_CONFIG}|${RESOLVED_REPO_ROOT}"
if [[ "${RALPH_CONFIG_LOADED:-}" != "$EXPECTED_LOADED_TUPLE" ]]; then
  # shellcheck source=lib/config.sh
  source "$SCRIPT_DIR/lib/config.sh" "$CONFIG_FILE"
fi

# shellcheck source=lib/linear.sh
source "$SCRIPT_DIR/lib/linear.sh"

approved_ids="$(linear_list_approved_issues)"
[[ -z "$approved_ids" ]] && exit 0

# Membership-test fixture for the approved set (space-delimited with leading
# and trailing space so substring match `*" $id "*` works for any id).
approved_set=" $(printf '%s' "$approved_ids" | tr '\n' ' ') "

toposort_input="$(mktemp)"
trap 'rm -f "$toposort_input"' EXIT

while IFS= read -r issue_id; do
  [[ -z "$issue_id" ]] && continue

  blockers_json="$(linear_get_issue_blockers "$issue_id")"

  # Pickup-ready check: every blocker must be either resolved (Done /
  # In Review) or Approved AND in this run's approved set. Approved
  # blockers ARE runnable in the same overnight session when they're
  # actually queued — toposort orders them so the parent dispatches first
  # and reaches In Review, then dag_base picks up the child against the
  # parent's branch. An Approved blocker that's NOT in the queue (e.g.
  # ralph-failed-labeled, in another project) cannot clear this run, and
  # toposort would silently treat it as "already done" — child would be
  # dispatched against main with a stale parent dependency.
  pickup_ready=1
  warning_emitted=0
  blocker_count="$(printf '%s' "$blockers_json" | jq 'length')"
  for (( i = 0; i < blocker_count; i++ )); do
    state="$(printf '%s' "$blockers_json" | jq -r ".[$i].state")"
    blocker_id="$(printf '%s' "$blockers_json" | jq -r ".[$i].id")"
    if [[ "$state" == "$RALPH_DONE_STATE" || "$state" == "$RALPH_REVIEW_STATE" ]]; then
      continue
    fi
    if [[ "$state" == "$RALPH_APPROVED_STATE" ]]; then
      if [[ "$approved_set" == *" $blocker_id "* ]]; then
        continue
      fi
      printf 'build_queue: skipping %s — Approved blocker %s is not in this run (likely ralph-failed-labeled or outside the configured project)\n' "$issue_id" "$blocker_id" >&2
      warning_emitted=1
      pickup_ready=0
      break
    fi
    pickup_ready=0
    break
  done
  if [[ "$pickup_ready" -eq 0 ]]; then
    if [[ "$warning_emitted" -eq 0 ]]; then
      printf 'build_queue: skipping %s — blocker(s) not pickup-ready\n' "$issue_id" >&2
    fi
    continue
  fi

  priority="$(linear issue view "$issue_id" --json --no-comments | jq -r '.priority')"
  blocker_ids="$(printf '%s' "$blockers_json" | jq -r '.[].id' | tr '\n' ' ')"
  printf '%s %s %s\n' "$issue_id" "$priority" "$blocker_ids" >> "$toposort_input"
done <<< "$approved_ids"

[[ ! -s "$toposort_input" ]] && exit 0

"$SCRIPT_DIR/toposort.sh" < "$toposort_input"
