#!/usr/bin/env bash
# Read-only renderer for /sr-status. Reads
# .sensible-ralph/ordered_queue.txt's `# run_id: <iso>` header (ENG-287:
# the orchestrator publishes the queue file with the header before any
# progress.json record lands), then partitions records from
# .sensible-ralph/progress.json that match that run_id into
# Done / Running / Queued and prints a sectioned table.
#
# Side effects: NONE — no writes to Linear, git, the filesystem, or network.

set -euo pipefail

# Source plugin-wide libs from $CLAUDE_PLUGIN_ROOT/lib/. CLAUDE_PLUGIN_ROOT
# is exported by the Claude Code harness whenever the sensible-ralph plugin
# is enabled.
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  echo "sr-status: \$CLAUDE_PLUGIN_ROOT not set (sensible-ralph plugin not enabled?)" >&2
  exit 1
fi
# shellcheck source=../../../lib/worktree.sh
source "$CLAUDE_PLUGIN_ROOT/lib/worktree.sh"
# shellcheck source=../../../lib/defaults.sh
source "$CLAUDE_PLUGIN_ROOT/lib/defaults.sh"

# Repo root resolution must use _resolve_repo_root (not git rev-parse
# --show-toplevel) — the latter returns the linked-worktree path when
# invoked from a worktree, but .sensible-ralph/ lives at the main checkout root.
if ! repo_root="$(_resolve_repo_root 2>/dev/null)"; then
  echo "sr-status: not inside a git repository." >&2
  exit 1
fi

progress_file="$repo_root/.sensible-ralph/progress.json"
queue_file="$repo_root/.sensible-ralph/ordered_queue.txt"

_no_runs_message() {
  echo "No ralph runs recorded in this repo. Run /sr-start to dispatch the queue."
}

# No queue file → no committed run ever existed in this repo. Legitimate
# fresh-repo path; render the friendly hint and exit clean.
if [[ ! -f "$queue_file" ]]; then
  _no_runs_message
  exit 0
fi

# Parse `# run_id: <iso>` from line 1 of the queue file. Orchestrator-written
# files always carry it; absence means a header-less leftover from a prior
# plugin version. Error loud — re-running /sr-start regenerates the file.
queue_header="$(head -n 1 "$queue_file")"
if [[ "$queue_header" =~ ^\#[[:space:]]*run_id:[[:space:]]*(.+)$ ]]; then
  latest_run_id="${BASH_REMATCH[1]}"
else
  echo "sr-status: ordered_queue.txt missing '# run_id: <id>' header line — re-run /sr-start to regenerate." >&2
  exit 1
fi

# Header is present but progress.json may not exist yet — this is the
# orchestrator's setup-time gap between the commitment publish and the first
# `start` record landing. Initialize an empty record set and continue with
# partitioning logic so /sr-status renders Done(0)/Running(0)/Queued(N)
# honestly. Scoped strictly to "file does not exist" — unreadable or
# malformed progress.json crashes via set -e (intentional: integrity
# bug should surface, not be masked).
if [[ -f "$progress_file" ]]; then
  run_records="$(jq --arg run "$latest_run_id" '[.[] | select(.run_id == $run)]' < "$progress_file")"
else
  run_records='[]'
fi
end_records="$(printf '%s' "$run_records" | jq '[.[] | select(.event == "end")]')"
start_records="$(printf '%s' "$run_records" | jq '[.[] | select(.event == "start")]')"

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
# Skip comment lines (the `# run_id: ...` header on line 1 and any future
# metadata). A failed start-record write would leave the issue in
# ordered_queue.txt with no record in progress.json — it ends up here as
# Queued, mis-rendered until the end record lands and reclassifies it as Done.
queued_issues=()
done_set=" ${done_issues[*]:-} "
running_set=" ${running_issues[*]:-} "
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line//[[:space:]]/}"
  [[ -z "$line" ]] && continue
  [[ "$line" == \#* ]] && continue
  if [[ "$done_set" != *" $line "* && "$running_set" != *" $line "* ]]; then
    queued_issues+=("$line")
  fi
done < "$queue_file"

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

    # ENG-308: diagnostic sub-block on non-success rows. Three lines, each
    # gated on the presence and non-emptiness of one specific record field —
    # no per-outcome reasoning. The single outcome-named rule is the
    # whole-sub-block override for in_review: scannability for green
    # outcomes wins over having diagnostic plumbing on success rows.
    if [[ "$outcome" == "in_review" ]]; then
      continue
    fi
    hint="$(printf '%s' "$rec" | jq -r '.hint // ""')"
    transcript_path="$(printf '%s' "$rec" | jq -r '.transcript_path // ""')"
    worktree_log_path="$(printf '%s' "$rec" | jq -r '.worktree_log_path // ""')"
    if [[ -n "$hint" ]]; then
      # ↳ is U+21B3, encoded as the UTF-8 byte sequence \xe2\x86\xb3 so the
      # renderer doesn't depend on the source file's encoding being preserved
      # through editing tools.
      printf '    \xe2\x86\xb3 %s\n' "$hint"
    fi
    if [[ -n "$worktree_log_path" ]]; then
      printf '      transcript: %s\n' "$worktree_log_path"
    fi
    if [[ -n "$transcript_path" ]]; then
      printf '      session: %s\n' "$transcript_path"
    fi
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

# Tip line — only when Running is non-empty. Prefers the dispatch-time
# worktree_log_path persisted into the start record (ENG-308) so the tip
# remains accurate after CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME or
# CLAUDE_PLUGIN_OPTION_WORKTREE_BASE is reconfigured mid-run. Falls back to
# live-config reconstruction for legacy start records that predate this
# change.
if [[ "${#running_issues[@]}" -ge 1 ]]; then
  first_running="${running_issues[0]}"
  first_record="$(printf '%s' "$start_records" | jq -c --arg i "$first_running" '.[] | select(.issue == $i)')"
  tip_path="$(printf '%s' "$first_record" | jq -r '.worktree_log_path // ""')"
  if [[ -z "$tip_path" ]]; then
    first_branch="$(printf '%s' "$first_record" | jq -r '.branch')"
    # Anchor to repo_root and normalize WORKTREE_BASE the same way
    # worktree_path_for_issue does (strip leading/trailing slashes), so the
    # tip matches the actual worktree path even when WORKTREE_BASE is
    # configured as `/.worktrees/` (a documented-supported value — see
    # worktree.bats).
    wt_base="${CLAUDE_PLUGIN_OPTION_WORKTREE_BASE#/}"
    wt_base="${wt_base%/}"
    tip_path="$repo_root/$wt_base/$first_branch/$CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME"
  fi
  # Single-quote the full path so operators can copy-paste even when any
  # component contains spaces.
  printf "Tip: tail '%s' to see live session output.\n" "$tip_path"
fi
