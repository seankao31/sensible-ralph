#!/usr/bin/env bash
# Read-only renderer for /ralph-status. Reads .ralph/progress.json and
# .ralph/ordered_queue.txt at the repo root, partitions records from the
# chronologically-latest run_id into Done / Running / Queued, and prints a
# sectioned table.
#
# Side effects: NONE — no writes to Linear, git, the filesystem, or network.

set -euo pipefail

# Source ralph-start libs from the bundled skill — same pattern close-issue
# and ralph-spec use. CLAUDE_PLUGIN_ROOT is exported by the Claude Code
# harness whenever the sensible-ralph plugin is enabled.
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  echo "ralph-status: \$CLAUDE_PLUGIN_ROOT not set (sensible-ralph plugin not enabled?)" >&2
  exit 1
fi
# shellcheck source=../../ralph-start/scripts/lib/worktree.sh
source "$CLAUDE_PLUGIN_ROOT/skills/ralph-start/scripts/lib/worktree.sh"
# shellcheck source=../../ralph-start/scripts/lib/defaults.sh
source "$CLAUDE_PLUGIN_ROOT/skills/ralph-start/scripts/lib/defaults.sh"

# Repo root resolution must use _resolve_repo_root (not git rev-parse
# --show-toplevel) — the latter returns the linked-worktree path when
# invoked from a worktree, but .ralph/ lives at the main checkout root.
if ! repo_root="$(_resolve_repo_root 2>/dev/null)"; then
  echo "ralph-status: not inside a git repository." >&2
  exit 1
fi

progress_file="$repo_root/.ralph/progress.json"
queue_file="$repo_root/.ralph/ordered_queue.txt"

_no_runs_message() {
  echo "No ralph runs recorded in this repo. Run /ralph-start to dispatch the queue."
}

if [[ ! -f "$progress_file" ]]; then
  _no_runs_message
  exit 0
fi

# Latest run_id by chronological sort (explicit fromdateiso8601 — orchestrator
# always writes normalized UTC). Beats lexicographic sort which silently
# breaks on cross-timezone runs.
latest_run_id="$(jq -r '
  [.[].run_id]
  | unique
  | map(select(. != null))
  | sort_by(fromdateiso8601)
  | last // empty
' < "$progress_file")"

if [[ -z "$latest_run_id" ]]; then
  _no_runs_message
  exit 0
fi

# Filter records to the latest run, then partition by event. Pre-event-field
# legacy records are dropped here: they belong to older run_ids by the time
# this code path matters (since new runs always have newer timestamps), so
# the filter naturally excludes them.
run_records="$(jq --arg run "$latest_run_id" '[.[] | select(.run_id == $run)]' < "$progress_file")"
end_records="$(printf '%s' "$run_records" | jq '[.[] | select(.event == "end")]')"
start_records="$(printf '%s' "$run_records" | jq '[.[] | select(.event == "start")]')"

end_count="$(printf '%s' "$end_records" | jq 'length')"
start_count="$(printf '%s' "$start_records" | jq 'length')"

# Latest run is legacy-only (no event field on any record): fall through.
# Becomes unreachable for the latest run_id once the first new run completes.
if (( end_count == 0 && start_count == 0 )); then
  _no_runs_message
  exit 0
fi

# Done = issues with an end record. End-only records (failed start-record
# write) still classify here — the Done row format reads only end-record
# fields, so a missing start is invisible to the operator.
done_issues=()
while IFS= read -r issue; do
  [[ -n "$issue" ]] && done_issues+=("$issue")
done < <(printf '%s' "$end_records" | jq -r '[.[].issue] | unique | .[]')

# Running = issues with a start record but no matching end record.
running_issues=()
while IFS= read -r issue; do
  [[ -n "$issue" ]] && running_issues+=("$issue")
done < <(printf '%s' "$run_records" | jq -r '
  ([.[] | select(.event == "start") | .issue] | unique) as $starts
  | ([.[] | select(.event == "end") | .issue] | unique) as $ends
  | $starts - $ends
  | .[]
')

# Queued = ordered_queue.txt minus Done minus Running. Preserves queue order.
# A failed start-record write would leave the issue in ordered_queue.txt with
# no record in progress.json — it ends up here as Queued, mis-rendered until
# the end record lands and reclassifies it as Done.
queued_issues=()
if [[ -f "$queue_file" ]]; then
  done_set=" ${done_issues[*]:-} "
  running_set=" ${running_issues[*]:-} "
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//[[:space:]]/}"
    [[ -z "$line" ]] && continue
    if [[ "$done_set" != *" $line "* && "$running_set" != *" $line "* ]]; then
      queued_issues+=("$line")
    fi
  done < "$queue_file"
fi

# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

# Compact duration: Xh Ym for ≥1h, Xm for ≥1min, <1m otherwise.
# Scannable, not precise — operators glance at this, they don't grep it.
_format_duration() {
  local secs="$1"
  if (( secs >= 3600 )); then
    printf '%dh %dm' "$(( secs / 3600 ))" "$(( (secs % 3600) / 60 ))"
  elif (( secs >= 60 )); then
    printf '%dm' "$(( secs / 60 ))"
  else
    printf '<1m'
  fi
}

# Render an end-record outcome. failed gets the exit code; setup_failed gets
# the failing step; everything else renders bare.
_format_outcome() {
  local outcome="$1" exit_code="$2" failed_step="$3"
  case "$outcome" in
    failed)        printf 'failed (exit %s)' "$exit_code" ;;
    setup_failed)  printf 'setup_failed (%s)' "$failed_step" ;;
    *)             printf '%s' "$outcome" ;;
  esac
}

# ISO 8601 UTC ("2026-04-22T18:42:00Z") -> epoch seconds. BSD/macOS date and
# GNU/Linux date have incompatible parsing flags; detect by feature probe.
_iso_to_epoch() {
  local iso="$1"
  if date --version >/dev/null 2>&1; then
    date -u -d "$iso" +%s
  else
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s
  fi
}

# ISO 8601 UTC -> "HH:MM" UTC. Substring slice is safe because orchestrator
# always writes the same fixed-width format.
_iso_hhmm() {
  printf '%s' "${1:11:5}"
}

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------

now_epoch="$(date -u +%s)"

# Done
echo "=== Done (${#done_issues[@]}) ==="
if [[ "${#done_issues[@]}" -eq 0 ]]; then
  echo "  (none)"
else
  for issue in "${done_issues[@]}"; do
    rec="$(printf '%s' "$end_records" | jq -c --arg i "$issue" '.[] | select(.issue == $i)')"
    outcome="$(printf '%s' "$rec" | jq -r '.outcome // "unknown"')"
    exit_code="$(printf '%s' "$rec" | jq -r '.exit_code // 0')"
    failed_step="$(printf '%s' "$rec" | jq -r '.failed_step // "unknown"')"
    duration="$(printf '%s' "$rec" | jq -r '.duration_seconds // 0')"
    outcome_str="$(_format_outcome "$outcome" "$exit_code" "$failed_step")"
    duration_str="$(_format_duration "$duration")"
    printf '  %-8s %-25s %s\n' "$issue" "$outcome_str" "$duration_str"
  done
fi
echo

# Running
echo "=== Running (${#running_issues[@]}) ==="
if [[ "${#running_issues[@]}" -eq 0 ]]; then
  echo "  (none)"
else
  for issue in "${running_issues[@]}"; do
    rec="$(printf '%s' "$start_records" | jq -c --arg i "$issue" '.[] | select(.issue == $i)')"
    ts="$(printf '%s' "$rec" | jq -r '.timestamp')"
    start_epoch="$(_iso_to_epoch "$ts")"
    elapsed=$(( now_epoch - start_epoch ))
    elapsed_str="$(_format_duration "$elapsed")"
    started_at="$(_iso_hhmm "$ts") UTC"
    printf '  %-8s %-25s %s  (started %s)\n' "$issue" "In Progress" "$elapsed_str" "$started_at"
  done
fi
echo

# Queued
echo "=== Queued (${#queued_issues[@]}) ==="
if [[ "${#queued_issues[@]}" -eq 0 ]]; then
  echo "  (none)"
else
  for issue in "${queued_issues[@]}"; do
    printf '  %s\n' "$issue"
  done
fi
echo

# Footer
echo "Run started: $latest_run_id"

# Tip line — only when Running is non-empty. Uses both configured paths so
# the suggestion stays accurate when the operator overrides defaults.
# Branch comes from the start record (not a lowercased-issue-ID assumption)
# so the path stays correct even when the branch name deviates from the
# expected <issue-id>-<slug> pattern.
if [[ "${#running_issues[@]}" -ge 1 ]]; then
  first_running="${running_issues[0]}"
  first_branch="$(printf '%s' "$start_records" | jq -r --arg i "$first_running" '.[] | select(.issue == $i) | .branch')"
  # Anchor to repo_root and normalize WORKTREE_BASE the same way
  # worktree_path_for_issue does (strip leading/trailing slashes), so the tip
  # matches the actual worktree path even when WORKTREE_BASE is configured as
  # `/.worktrees/` (a documented-supported value — see worktree.bats).
  # Single-quote the full path so operators can copy-paste even when any
  # component contains spaces.
  wt_base="${CLAUDE_PLUGIN_OPTION_WORKTREE_BASE#/}"
  wt_base="${wt_base%/}"
  printf "Tip: tail '%s/%s/%s/%s' to see live session output.\n" \
    "$repo_root" "$wt_base" "$first_branch" "$CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME"
fi
