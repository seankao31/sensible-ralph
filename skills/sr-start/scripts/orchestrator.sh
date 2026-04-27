#!/usr/bin/env bash
set -euo pipefail

# Dispatch loop: consume an ordered queue of issue IDs, pre-create the
# worktree at the DAG-chosen base, transition Linear state, invoke
# `claude -p` with the rendered prompt, classify outcomes using the
# Linear post-dispatch state (Q2 finding: exit 0 alone does NOT imply
# success — `claude -p --permission-mode auto` refuses and continues),
# propagate failure taint to transitive downstream dependents, and
# append a per-issue record to progress.json.
#
# Input contract: $1 is a file path containing one issue ID per line,
# pre-sorted by toposort.sh. .sensible-ralph/progress.json is written under the repo root
# (resolved via $PLUGIN_ROOT/lib/worktree.sh::_resolve_repo_root), independent of cwd.
#
# Required env: CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE,
#               CLAUDE_PLUGIN_OPTION_REVIEW_STATE,
#               CLAUDE_PLUGIN_OPTION_FAILED_LABEL,
#               CLAUDE_PLUGIN_OPTION_WORKTREE_BASE,
#               CLAUDE_PLUGIN_OPTION_MODEL,
#               CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME
# (Claude Code harness auto-exports these from the plugin's userConfig.)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

# shellcheck source=../../../lib/defaults.sh
source "$PLUGIN_ROOT/lib/defaults.sh"

# Auto-source scope unless the load marker matches THIS invocation's repo +
# scope-file content. SENSIBLE_RALPH_SCOPE_LOADED is "<repo-root>|<scope-hash>"; if the
# operator ran another repo's ralph in the same shell, or edited .sensible-ralph.json
# mid-session, the marker won't match and we re-source. Removes the
# bash-shell requirement for callers (this script has a bash shebang and
# sources scope itself, so invoke from zsh/fish/sh).
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

# shellcheck source=../../../lib/worktree.sh
source "$PLUGIN_ROOT/lib/worktree.sh"

queue_file="${1:?orchestrator.sh: queue file path required as \$1}"

# Ensure the consumer-repo .sensible-ralph/ directory exists once at startup so the
# atomic mktemp+mv pattern in _progress_append has a destination on the first
# record, no matter which dispatch path writes first.
repo_root="$(_resolve_repo_root)"
mkdir -p "$repo_root/.sensible-ralph"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Per-issue title lookup. The stubbed test harness overrides this; in
# production it shells out to `linear issue view`.
if ! declare -F linear_get_issue_title >/dev/null 2>&1; then
  linear_get_issue_title() {
    local issue_id="$1"
    linear issue view "$issue_id" --json --no-comments | jq -r '.title'
  }
fi

# Post-dispatch state lookup. Also overridable by tests.
if ! declare -F linear_get_issue_state >/dev/null 2>&1; then
  linear_get_issue_state() {
    local issue_id="$1"
    linear issue view "$issue_id" --json --no-comments | jq -r '.state.name'
  }
fi

# Append a record (passed as a JSON object on stdin) to progress.json.
#
# Record schema (fields vary by event/outcome):
#   event             "start" (dispatch about to invoke claude) | "end" (final
#                     per-issue outcome). Discriminator added in ENG-241 so
#                     /sr-status can render in-flight Running rows; pre-
#                     ENG-241 records have no event field and are filtered
#                     out by run_id selection (latest run only).
#   issue             Linear issue id (always present)
#   timestamp         ISO 8601 UTC — per-issue dispatch start (same field name
#                     in both start and end records, no aliases)
#   run_id            ISO 8601 UTC — invocation id, shared by every record from
#                     the same orchestrator run (design Component 6). Groups
#                     records for later auditing / cross-run diffing.
#   branch, base      start records and dispatched-outcome end records
#                     (in_review / exit_clean_no_review / failed / unknown_post_state)
#   outcome           end records only:
#                     in_review | exit_clean_no_review | failed | setup_failed |
#                     local_residue | unknown_post_state | skipped
#   exit_code         dispatched-outcome end records only
#   duration_seconds  dispatched-outcome end records only
#   failed_step       setup_failed end records only
#
# Atomicity: mktemp-in-same-dir + jq read-modify-write + `mv` is atomic on
# POSIX for same-filesystem renames. A crash mid-write leaves the previous
# progress.json intact — never a partially-written file.
#
# Known limitation: this function uses no flock. Concurrent orchestrator runs
# against the same progress.json would race (last-writer-wins loses updates).
# Not a supported scenario — `/sr-start` is single-invocation by design.
_progress_append() {
  local record="$1"
  local repo_root
  repo_root="$(_resolve_repo_root)" || return 1
  local progress_file="$repo_root/.sensible-ralph/progress.json"
  local tmp; tmp="$(mktemp "${progress_file}.XXXXXX")"
  if [[ -s "$progress_file" ]]; then
    jq --argjson rec "$record" '. + [$rec]' "$progress_file" > "$tmp"
  else
    jq -n --argjson rec "$record" '[$rec]' > "$tmp"
  fi
  mv "$tmp" "$progress_file"
}

# Membership test for a space-delimited id list stored in a scalar.
_contains_id() {
  local needle="$1"
  local haystack="$2"
  [[ " $haystack " == *" $needle "* ]]
}

# ---------------------------------------------------------------------------
# Phase 1: load queue, build parent -> children map for taint propagation.
# ---------------------------------------------------------------------------

queued_ids=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "${line//[[:space:]]/}" ]] && continue
  queued_ids+=("$line")
done < "$queue_file"

if [[ "${#queued_ids[@]}" -eq 0 ]]; then
  exit 0
fi

# Invocation id — shared by every progress.json record written by this run.
# Groups records from the same orchestrator invocation for later auditing
# (design doc Component 6). ISO 8601 UTC.
run_id="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Parallel arrays encoding the parent->children map (bash 3.2 has no assoc arrays).
# _parent_ids[i] is the parent; _child_lists[i] is a space-delimited list of its children.
_parent_ids=()
_child_lists=()

_map_add_child() {
  local parent="$1" child="$2"
  local i
  for (( i = 0; i < ${#_parent_ids[@]}; i++ )); do
    if [[ "${_parent_ids[$i]}" == "$parent" ]]; then
      _child_lists[$i]="${_child_lists[$i]} $child"
      return 0
    fi
  done
  _parent_ids+=("$parent")
  _child_lists+=("$child")
}

_map_children_of() {
  local parent="$1"
  local i
  for (( i = 0; i < ${#_parent_ids[@]}; i++ )); do
    if [[ "${_parent_ids[$i]}" == "$parent" ]]; then
      printf '%s' "${_child_lists[$i]}"
      return 0
    fi
  done
}

for issue_id in "${queued_ids[@]}"; do
  # Per-issue fault isolation: if the blocker fetch fails for one issue, skip
  # map-building for that issue and continue. Its descendants won't be known
  # in the taint map, so a later failure of this issue won't taint its
  # children — a documented degradation.
  if ! blockers_json="$(linear_get_issue_blockers "$issue_id" 2>/dev/null)"; then
    printf 'orchestrator: failed to fetch blockers for %s — taint propagation will be incomplete for this issue\n' "$issue_id" >&2
    continue
  fi
  blocker_count="$(printf '%s' "$blockers_json" | jq 'length')"
  for (( i = 0; i < blocker_count; i++ )); do
    blocker_id="$(printf '%s' "$blockers_json" | jq -r ".[$i].id")"
    _map_add_child "$blocker_id" "$issue_id"
  done
done

# Taint: BFS from a failed issue through the parent->children map.
# Appends all transitive descendants to the tainted_ids list.
tainted_ids=""
_taint_descendants() {
  local start="$1"
  local queue="$start"
  while [[ -n "$queue" ]]; do
    local head="${queue%% *}"
    if [[ "$queue" == *" "* ]]; then
      queue="${queue#* }"
    else
      queue=""
    fi
    local children; children="$(_map_children_of "$head")"
    local child
    for child in $children; do
      if ! _contains_id "$child" "$tainted_ids"; then
        tainted_ids="$tainted_ids $child"
        queue="$queue $child"
      fi
    done
  done
}

# Record a setup_failed outcome and taint downstream dependents. Used by the
# per-issue fault-isolation path so one bad issue can't abort the whole run.
_record_setup_failure() {
  local issue_id="$1"
  local failed_step="$2"
  local timestamp="$3"
  linear_add_label "$issue_id" "$CLAUDE_PLUGIN_OPTION_FAILED_LABEL" || true
  _taint_descendants "$issue_id"
  local record
  record="$(jq -n \
    --arg issue "$issue_id" \
    --arg outcome "setup_failed" \
    --arg step "$failed_step" \
    --arg ts "$timestamp" \
    --arg run "$run_id" \
    '{event: "end", issue: $issue, outcome: $outcome, failed_step: $step, timestamp: $ts, run_id: $run}')"
  _progress_append "$record"
}

# Record a local_residue outcome WITHOUT mutating Linear. Used when the target
# worktree path or branch already exists at the start of dispatch — the
# residue is operator state (manual mkdir, prior crashed run, in-flight
# branch) that this invocation did not create. We must not label the issue
# ralph-failed (the issue itself is fine; only the local environment needs
# manual cleanup) and must not taint descendants (operator will clean up and
# re-run, at which point the normal dispatch path will execute).
_record_local_residue() {
  local issue_id="$1"
  local residue_path="$2"
  local residue_branch="$3"
  local timestamp="$4"
  local record
  record="$(jq -n \
    --arg issue "$issue_id" \
    --arg outcome "local_residue" \
    --arg path "$residue_path" \
    --arg branch "$residue_branch" \
    --arg ts "$timestamp" \
    --arg run "$run_id" \
    '{event: "end", issue: $issue, outcome: $outcome, residue_path: $path, residue_branch: $branch, timestamp: $ts, run_id: $run}')"
  _progress_append "$record"
}

# Record an unknown_post_state outcome WITHOUT mutating Linear. Used when
# claude exited 0 but the post-dispatch Linear state fetch failed transiently.
# We can't tell whether the session truly succeeded (transitioned to In Review)
# or stopped short — collapsing to exit_clean_no_review on a degraded read
# would falsely label a real success as failed and taint its descendants.
# Operator inspects progress.json and the Linear UI to disambiguate.
_record_unknown_post_state() {
  local issue_id="$1"
  local branch="$2"
  local base="$3"
  local exit_code="$4"
  local duration="$5"
  local timestamp="$6"
  local record
  record="$(jq -n \
    --arg issue "$issue_id" \
    --arg branch "$branch" \
    --arg base "$base" \
    --arg outcome "unknown_post_state" \
    --argjson exit_code "$exit_code" \
    --argjson duration "$duration" \
    --arg ts "$timestamp" \
    --arg run "$run_id" \
    '{event: "end", issue: $issue, branch: $branch, base: $base, outcome: $outcome, exit_code: $exit_code, duration_seconds: $duration, timestamp: $ts, run_id: $run}')"
  _progress_append "$record"
}

# Best-effort cleanup after a post-worktree-creation setup failure. Without
# this, a failed setup step (e.g. .sensible-ralph-base-sha write or linear_set_state)
# leaves both the worktree directory and the branch in place, so the next
# orchestrator run trips over `git worktree add -b <branch>` ("branch already
# exists") and the issue is permanently blocked until a human cleans up.
#
# Gated on worktree-directory existence: `git worktree add -b` is atomic —
# it either creates BOTH the worktree directory AND the branch, or NEITHER.
# If the directory doesn't exist, git didn't create a new branch, so any
# branch of that name is pre-existing work and must NOT be deleted.
#
# `--force` is required because .sensible-ralph-base-sha (written pre-dispatch) is an
# untracked file that otherwise causes `git worktree remove` to refuse. The
# `git worktree prune --expire now` call sweeps any stale metadata left behind
# by the rm -rf fallback; without `--expire now` the default expiry window
# keeps the admin entry alive and `git branch -D` refuses to delete a
# "checked out" ref.
_cleanup_worktree() {
  local path="$1" branch="$2"
  if [[ ! -d "$path" ]]; then
    return 0
  fi
  git worktree remove --force "$path" 2>/dev/null || {
    rm -rf "$path"
    git worktree prune --expire now 2>/dev/null || true
  }
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git branch -D "$branch" 2>/dev/null || true
  fi
}

# Per-issue setup + dispatch. Returns 0 on successful dispatch (regardless of
# the session's outcome — hard/soft failures are still "dispatched"), and
# returns 1 if setup itself failed before claude could be invoked. The caller
# treats a non-zero return as "keep going with the next issue".
_dispatch_issue() {
  local issue_id="$1"
  local timestamp; timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local start_epoch; start_epoch="$(date +%s)"

  # Setup steps run with explicit error handling so any failure is caught,
  # recorded, and doesn't abort the outer loop.
  local branch title base_out path base_sha parents
  set +e

  branch="$(linear_get_issue_branch "$issue_id")"
  if [[ $? -ne 0 || -z "$branch" ]]; then
    set -e
    _record_setup_failure "$issue_id" "linear_get_issue_branch" "$timestamp"
    return 1
  fi
  # `jq -r '.branchName'` emits the literal string "null" when the field is
  # missing. Treat that as a missing branch name — worktree creation would
  # otherwise create a branch literally named "null".
  if [[ "$branch" == "null" ]]; then
    set -e
    _record_setup_failure "$issue_id" "missing_branch_name" "$timestamp"
    return 1
  fi

  title="$(linear_get_issue_title "$issue_id")"
  if [[ $? -ne 0 ]]; then
    set -e
    _record_setup_failure "$issue_id" "linear_get_issue_title" "$timestamp"
    return 1
  fi

  base_out="$("$SCRIPT_DIR/dag_base.sh" "$issue_id")"
  if [[ $? -ne 0 ]]; then
    set -e
    _record_setup_failure "$issue_id" "dag_base" "$timestamp"
    return 1
  fi

  # Validate dag_base output: must be non-empty and begin with "main",
  # "INTEGRATION ", or a plausible branch token (no whitespace).
  if [[ -z "${base_out//[[:space:]]/}" ]]; then
    set -e
    printf 'orchestrator: dag_base.sh returned empty base for %s\n' "$issue_id" >&2
    _record_setup_failure "$issue_id" "dag_base_empty" "$timestamp"
    return 1
  fi
  if [[ "$base_out" != "main" && "$base_out" != INTEGRATION\ * && "$base_out" =~ [[:space:]] ]]; then
    set -e
    printf 'orchestrator: dag_base.sh returned malformed base for %s: %q\n' "$issue_id" "$base_out" >&2
    _record_setup_failure "$issue_id" "dag_base_malformed" "$timestamp"
    return 1
  fi

  path="$(worktree_path_for_issue "$branch")"
  if [[ $? -ne 0 || -z "$path" ]]; then
    set -e
    _record_setup_failure "$issue_id" "worktree_path_for_issue" "$timestamp"
    return 1
  fi

  # ENG-279: classify the per-issue (branch, path) pair before deciding whether
  # to reuse (the common case under per-issue branch lifecycle, where /sr-spec
  # step 7 already created branch+worktree) or create (fallback for manual
  # issues / legacy state). Partial states — exactly one of branch/path —
  # are operator state we cannot interpret and surface as local_residue.
  local _brwt _brwt_state _brwt_cause
  _brwt="$(worktree_branch_state_for_issue "$branch" "$path")"
  _brwt_state="${_brwt%%$'\t'*}"
  _brwt_cause="${_brwt#*$'\t'}"

  if [[ "$_brwt_state" == "partial" ]]; then
    set -e
    printf 'orchestrator: partial residue for %s — %s exists in isolation. Manual cleanup required.\n' \
      "$issue_id" "$_brwt_cause" >&2
    _record_local_residue "$issue_id" "$path" "$branch" "$timestamp"
    return 1
  fi

  # Parse base_out into a parent list (zero, one, or many parents). Same
  # interpretation in both reuse and create paths — but applied differently:
  # reuse merges into the existing branch; create branches off and (for
  # INTEGRATION) merges onto the trunk-based new branch.
  local merge_parents=()
  if [[ "$base_out" == INTEGRATION\ * ]]; then
    # shellcheck disable=SC2206
    merge_parents=(${base_out#INTEGRATION })
  elif [[ "$base_out" != "$SENSIBLE_RALPH_DEFAULT_BASE_BRANCH" ]]; then
    merge_parents=("$base_out")
  fi

  if [[ "$_brwt_state" == "both_exist" ]]; then
    # Reuse path: branch+worktree already exist (from /sr-spec step 7 or a
    # prior dispatch). Merge in any in-review parents into the existing
    # branch, then write base-sha = HEAD of the (possibly merged) worktree.
    # On single-parent conflict the helper returns 0 with the worktree in
    # MERGING state (HEAD = pre-merge spec commit) — base-sha captures that
    # spec commit so the agent's resolution commit lands in /prepare-for-
    # review's diff. On multi-parent conflict the helper aborts and returns
    # non-zero (subsequent parents would otherwise be silently dropped).
    worktree_merge_parents "$path" ${merge_parents[@]+"${merge_parents[@]}"}
    if [[ $? -ne 0 ]]; then
      set -e
      _record_setup_failure "$issue_id" "worktree_merge_parents" "$timestamp"
      return 1
    fi
    base_sha="$(git -C "$path" rev-parse HEAD)"
  else
    # neither path: fallback create path. Mirrors today's behavior — branch
    # off the chosen base, then (for INTEGRATION) merge the parent list onto
    # the new branch.
    #
    # Worktree creation helpers can fail AFTER `git worktree add` has already
    # succeeded (e.g. a merge error mid-integration). Cleanup must run on
    # failure so a stale branch/dir doesn't block the next run. The state
    # check above filtered out partial residue, so any state at $path here
    # was created by this invocation and is safe to remove.
    if [[ "$base_out" == INTEGRATION\ * ]]; then
      worktree_create_with_integration "$path" "$branch" "${merge_parents[@]}"
      if [[ $? -ne 0 ]]; then
        set -e
        _cleanup_worktree "$path" "$branch"
        _record_setup_failure "$issue_id" "worktree_create_with_integration" "$timestamp"
        return 1
      fi
    else
      worktree_create_at_base "$path" "$branch" "$base_out"
      if [[ $? -ne 0 ]]; then
        set -e
        _cleanup_worktree "$path" "$branch"
        _record_setup_failure "$issue_id" "worktree_create_at_base" "$timestamp"
        return 1
      fi
    fi
    # ENG-279: capture HEAD AFTER the helper returns (post-merge in
    # INTEGRATION mode, post-create-no-merge otherwise). Today's pre-merge
    # capture in the INTEGRATION case included parent commits in the
    # prepare-for-review diff; post-merge HEAD makes parent commits ancestors
    # of base-sha → correctly excluded.
    base_sha="$(git -C "$path" rev-parse HEAD)"
  fi

  # Record base SHA before dispatch (prepare-for-review contract, ENG-182)
  printf '%s\n' "$base_sha" > "$path/.sensible-ralph-base-sha"
  if [[ $? -ne 0 ]]; then
    set -e
    # Cleanup only on the create path — never tear down a reused branch+worktree
    # the operator already populated via /sr-spec.
    if [[ "$_brwt_state" == "neither" ]]; then
      _cleanup_worktree "$path" "$branch"
    fi
    _record_setup_failure "$issue_id" "write_base_sha" "$timestamp"
    return 1
  fi

  # Transition Linear state to In Progress
  linear_set_state "$issue_id" "$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE"
  if [[ $? -ne 0 ]]; then
    set -e
    # Cleanup only on the create path — a reused branch+worktree predates
    # this invocation and must not be torn down on a transient setup failure.
    if [[ "$_brwt_state" == "neither" ]]; then
      _cleanup_worktree "$path" "$branch"
    fi
    _record_setup_failure "$issue_id" "linear_set_state" "$timestamp"
    return 1
  fi

  set -e

  # Dispatch prompt: autonomous-mode preamble (overrides usual CLAUDE.md
  # behavior — escape-hatch to "post comment + exit clean" for anything
  # requiring human input) followed by the /sr-implement invocation.
  #
  # Prepending here (not in sr-implement's SKILL.md) puts the rules in
  # context from token zero, so any decision between session start and the
  # skill's load still runs under autonomous-mode rules. The blank line
  # between preamble and slash command ensures the command starts on its
  # own line for the harness's slash-command recognizer.
  local preamble
  preamble="$(cat "$SCRIPT_DIR/autonomous-preamble.md")"
  local prompt="${preamble}"$'\n\n'"/sr-implement $issue_id"

  # Dispatch claude from the worktree cwd, tee-ing output to the log file
  # without letting tee mask claude's exit code.
  #
  # We run the pipeline in a subshell so `cd` is scoped, and have the subshell
  # exit with claude's exit code (not tee's). `set +e` / explicit capture keeps
  # the outer `set -e` from aborting on non-zero.
  local claude_exit=0

  # Live-status start record. Written immediately before the claude -p subshell
  # so /sr-status can render an in-flight Running row. Best-effort —
  # _progress_append failure does not abort dispatch (the matching end record
  # still lands when claude exits, and /sr-status would just be missing
  # this issue from the Running count for the gap window).
  #
  # Use a fresh timestamp here — not the `timestamp` captured at the top of
  # _dispatch_issue — so that /sr-status elapsed time reflects when claude
  # actually started, not when setup began (which can include Integration
  # branch merges, Linear state transitions, etc.).
  # Capture both the ISO timestamp and the matching epoch so the end record's
  # `timestamp + duration_seconds` consistently means "claude end time".
  local dispatch_timestamp; dispatch_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local dispatch_epoch; dispatch_epoch="$(date +%s)"
  local start_record
  start_record="$(jq -n \
    --arg issue "$issue_id" \
    --arg branch "$branch" \
    --arg base "$base_out" \
    --arg ts "$dispatch_timestamp" \
    --arg run "$run_id" \
    '{event: "start", issue: $issue, branch: $branch, base: $base, timestamp: $ts, run_id: $run}')"
  _progress_append "$start_record" || true

  (
    cd "$path"
    set +e
    claude -p --permission-mode auto --model "$CLAUDE_PLUGIN_OPTION_MODEL" --name "$issue_id: $title" "$prompt" 2>&1 | tee "$path/$CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME"
    ec="${PIPESTATUS[0]}"
    exit "$ec"
  ) || claude_exit=$?

  local end_epoch; end_epoch="$(date +%s)"
  # Duration measures the claude session itself — keyed off dispatch_epoch
  # (claude-invocation moment), not start_epoch (function entry, pre-setup).
  # This keeps the end record's `timestamp + duration_seconds` invariant: it
  # always equals the claude-end wall-clock time.
  local duration=$(( end_epoch - dispatch_epoch ))

  # Classify using exit code AND Linear state (Q2 finding). A transient
  # failure fetching the post-dispatch state must NOT collapse to
  # exit_clean_no_review — that would label a true success as ralph-failed
  # whenever Linear's read path blips after a session that DID transition the
  # issue (codex adversarial review, finding B). Instead, distinguish
  # state-fetch failure from successful-fetch-with-non-review-state and emit
  # a separate unknown_post_state outcome with no label/taint.
  local post_state=""
  local state_fetch_ok=1
  if ! post_state="$(linear_get_issue_state "$issue_id" 2>/dev/null)"; then
    printf 'orchestrator: failed to fetch post-dispatch state for %s — recording unknown_post_state (no label, no taint)\n' "$issue_id" >&2
    state_fetch_ok=0
  fi

  if [[ "$claude_exit" -eq 0 && "$state_fetch_ok" -eq 0 ]]; then
    _record_unknown_post_state "$issue_id" "$branch" "$base_out" "$claude_exit" "$duration" "$dispatch_timestamp"
    return 0
  fi

  local outcome record
  if [[ "$claude_exit" -eq 0 && "$post_state" == "$CLAUDE_PLUGIN_OPTION_REVIEW_STATE" ]]; then
    outcome="in_review"
  elif [[ "$claude_exit" -eq 0 ]]; then
    outcome="exit_clean_no_review"
    linear_add_label "$issue_id" "$CLAUDE_PLUGIN_OPTION_FAILED_LABEL" || \
      printf 'orchestrator: failed to add %s label to %s (continuing)\n' "$CLAUDE_PLUGIN_OPTION_FAILED_LABEL" "$issue_id" >&2
    _taint_descendants "$issue_id"
  else
    outcome="failed"
    linear_add_label "$issue_id" "$CLAUDE_PLUGIN_OPTION_FAILED_LABEL" || \
      printf 'orchestrator: failed to add %s label to %s (continuing)\n' "$CLAUDE_PLUGIN_OPTION_FAILED_LABEL" "$issue_id" >&2
    _taint_descendants "$issue_id"
  fi

  record="$(jq -n \
    --arg issue "$issue_id" \
    --arg branch "$branch" \
    --arg base "$base_out" \
    --arg outcome "$outcome" \
    --argjson exit_code "$claude_exit" \
    --argjson duration "$duration" \
    --arg ts "$dispatch_timestamp" \
    --arg run "$run_id" \
    '{event: "end", issue: $issue, branch: $branch, base: $base, outcome: $outcome, exit_code: $exit_code, duration_seconds: $duration, timestamp: $ts, run_id: $run}')"
  _progress_append "$record"
  return 0
}

# ---------------------------------------------------------------------------
# Phase 2: dispatch loop
# ---------------------------------------------------------------------------

for issue_id in "${queued_ids[@]}"; do
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if _contains_id "$issue_id" "$tainted_ids"; then
    record="$(jq -n \
      --arg issue "$issue_id" \
      --arg ts "$timestamp" \
      --arg run "$run_id" \
      '{event: "end", issue: $issue, outcome: "skipped", timestamp: $ts, run_id: $run}')"
    _progress_append "$record"
    continue
  fi

  # Per-issue setup failures are handled inside _dispatch_issue; a non-zero
  # return just means "move on to the next issue".
  _dispatch_issue "$issue_id" || true
done
