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
# pre-sorted by toposort.sh. progress.json is written to the caller's
# cwd (typically the repo root).
#
# Required env: RALPH_REVIEW_STATE, RALPH_FAILED_LABEL, RALPH_WORKTREE_BASE,
#               RALPH_MODEL, RALPH_STDOUT_LOG, RALPH_PROMPT_TEMPLATE.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib/linear.sh
source "$SCRIPT_DIR/lib/linear.sh"
# shellcheck source=lib/worktree.sh
source "$SCRIPT_DIR/lib/worktree.sh"

queue_file="${1:?orchestrator.sh: queue file path required as \$1}"

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

# Append a record (passed as a JSON object on stdin) to progress.json
# atomically via tmpfile+mv. Task 10 hardens this further.
_progress_append() {
  local record="$1"
  local progress_file="$PWD/progress.json"
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
  blockers_json="$(linear_get_issue_blockers "$issue_id")"
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
  linear_add_label "$issue_id" "$RALPH_FAILED_LABEL" || true
  _taint_descendants "$issue_id"
  local record
  record="$(jq -n \
    --arg issue "$issue_id" \
    --arg outcome "setup_failed" \
    --arg step "$failed_step" \
    --arg ts "$timestamp" \
    '{issue: $issue, outcome: $outcome, failed_step: $step, timestamp: $ts}')"
  _progress_append "$record"
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

  # Create the worktree per base type, capturing the branch's creation point
  # (main's SHA for integration, post-create HEAD otherwise) for the
  # .ralph-base-sha contract consumed by prepare-for-review (ENG-182).
  if [[ "$base_out" == "main" ]]; then
    worktree_create_at_base "$path" "$branch" "main"
    if [[ $? -ne 0 ]]; then
      set -e
      _record_setup_failure "$issue_id" "worktree_create_at_base" "$timestamp"
      return 1
    fi
    base_sha="$(git -C "$path" rev-parse HEAD)"
  elif [[ "$base_out" == INTEGRATION\ * ]]; then
    # shellcheck disable=SC2206
    parents=(${base_out#INTEGRATION })
    # Capture main's SHA BEFORE any parent merges — that's the branch's true
    # creation point. Post-merge HEAD would pull parent commits into the
    # prepare-for-review diff, which must be scoped to this session's work.
    base_sha="$(git rev-parse main)"
    if [[ $? -ne 0 || -z "$base_sha" ]]; then
      set -e
      _record_setup_failure "$issue_id" "rev_parse_main" "$timestamp"
      return 1
    fi
    worktree_create_with_integration "$path" "$branch" "${parents[@]}"
    if [[ $? -ne 0 ]]; then
      set -e
      _record_setup_failure "$issue_id" "worktree_create_with_integration" "$timestamp"
      return 1
    fi
  else
    worktree_create_at_base "$path" "$branch" "$base_out"
    if [[ $? -ne 0 ]]; then
      set -e
      _record_setup_failure "$issue_id" "worktree_create_at_base" "$timestamp"
      return 1
    fi
    base_sha="$(git -C "$path" rev-parse HEAD)"
  fi

  # Record base SHA before dispatch (prepare-for-review contract, ENG-182)
  printf '%s\n' "$base_sha" > "$path/.ralph-base-sha"
  if [[ $? -ne 0 ]]; then
    set -e
    _record_setup_failure "$issue_id" "write_base_sha" "$timestamp"
    return 1
  fi

  # Transition Linear state to In Progress
  linear_set_state "$issue_id" "In Progress"
  if [[ $? -ne 0 ]]; then
    set -e
    _record_setup_failure "$issue_id" "linear_set_state" "$timestamp"
    return 1
  fi

  set -e

  # Render prompt
  local prompt="${RALPH_PROMPT_TEMPLATE//\$ISSUE_ID/$issue_id}"
  prompt="${prompt//\$ISSUE_TITLE/$title}"
  prompt="${prompt//\$BRANCH_NAME/$branch}"
  prompt="${prompt//\$WORKTREE_PATH/$path}"

  # Dispatch claude from the worktree cwd, tee-ing output to the log file
  # without letting tee mask claude's exit code.
  #
  # We run the pipeline in a subshell so `cd` is scoped, and have the subshell
  # exit with claude's exit code (not tee's). `set +e` / explicit capture keeps
  # the outer `set -e` from aborting on non-zero.
  local claude_exit=0
  (
    cd "$path"
    set +e
    claude -p --permission-mode auto --model "$RALPH_MODEL" --name "$issue_id: $title" "$prompt" 2>&1 | tee "$path/$RALPH_STDOUT_LOG"
    ec="${PIPESTATUS[0]}"
    exit "$ec"
  ) || claude_exit=$?

  local end_epoch; end_epoch="$(date +%s)"
  local duration=$(( end_epoch - start_epoch ))

  # Classify using exit code AND Linear state (Q2 finding)
  local post_state; post_state="$(linear_get_issue_state "$issue_id")"

  local outcome record
  if [[ "$claude_exit" -eq 0 && "$post_state" == "$RALPH_REVIEW_STATE" ]]; then
    outcome="in_review"
  elif [[ "$claude_exit" -eq 0 ]]; then
    outcome="exit_clean_no_review"
    linear_add_label "$issue_id" "$RALPH_FAILED_LABEL"
    _taint_descendants "$issue_id"
  else
    outcome="failed"
    linear_add_label "$issue_id" "$RALPH_FAILED_LABEL"
    _taint_descendants "$issue_id"
  fi

  record="$(jq -n \
    --arg issue "$issue_id" \
    --arg branch "$branch" \
    --arg base "$base_out" \
    --arg outcome "$outcome" \
    --argjson exit_code "$claude_exit" \
    --argjson duration "$duration" \
    --arg ts "$timestamp" \
    '{issue: $issue, branch: $branch, base: $base, outcome: $outcome, exit_code: $exit_code, duration_seconds: $duration, timestamp: $ts}')"
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
      '{issue: $issue, outcome: "skipped", timestamp: $ts}')"
    _progress_append "$record"
    continue
  fi

  # Per-issue setup failures are handled inside _dispatch_issue; a non-zero
  # return just means "move on to the next issue".
  _dispatch_issue "$issue_id" || true
done
