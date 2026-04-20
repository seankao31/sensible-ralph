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

  start_epoch="$(date +%s)"

  # Resolve branch + title
  branch="$(linear_get_issue_branch "$issue_id")"
  title="$(linear_get_issue_title "$issue_id")"

  # DAG base selection
  base_out="$("$SCRIPT_DIR/dag_base.sh" "$issue_id")"

  # Compute worktree path (requires REPO_ROOT via git rev-parse)
  path="$(worktree_path_for_issue "$branch")"

  # Create the worktree per base type
  if [[ "$base_out" == "main" ]]; then
    worktree_create_at_base "$path" "$branch" "main"
  elif [[ "$base_out" == INTEGRATION\ * ]]; then
    # shellcheck disable=SC2206
    parents=(${base_out#INTEGRATION })
    worktree_create_with_integration "$path" "$branch" "${parents[@]}"
  else
    worktree_create_at_base "$path" "$branch" "$base_out"
  fi

  # Record base SHA before dispatch (prepare-for-review contract, ENG-182)
  git -C "$path" rev-parse HEAD > "$path/.ralph-base-sha"

  # Transition Linear state to In Progress
  linear_set_state "$issue_id" "In Progress"

  # Render prompt
  prompt="${RALPH_PROMPT_TEMPLATE//\$ISSUE_ID/$issue_id}"
  prompt="${prompt//\$ISSUE_TITLE/$title}"
  prompt="${prompt//\$BRANCH_NAME/$branch}"
  prompt="${prompt//\$WORKTREE_PATH/$path}"

  # Dispatch claude from the worktree cwd, tee-ing output to the log file
  # without letting tee mask claude's exit code.
  #
  # We run the pipeline in a subshell so `cd` is scoped, and have the subshell
  # exit with claude's exit code (not tee's). `set +e` / explicit capture keeps
  # the outer `set -e` from aborting on non-zero.
  claude_exit=0
  (
    cd "$path"
    set +e
    claude -p --permission-mode auto --model "$RALPH_MODEL" --name "$issue_id: $title" "$prompt" 2>&1 | tee "$path/$RALPH_STDOUT_LOG"
    ec="${PIPESTATUS[0]}"
    exit "$ec"
  ) || claude_exit=$?

  end_epoch="$(date +%s)"
  duration=$(( end_epoch - start_epoch ))

  # Classify using exit code AND Linear state (Q2 finding)
  post_state="$(linear_get_issue_state "$issue_id")"

  if [[ "$claude_exit" -eq 0 && "$post_state" == "$RALPH_REVIEW_STATE" ]]; then
    outcome="in_review"
    record="$(jq -n \
      --arg issue "$issue_id" \
      --arg branch "$branch" \
      --arg base "$base_out" \
      --arg outcome "$outcome" \
      --argjson exit_code "$claude_exit" \
      --argjson duration "$duration" \
      --arg ts "$timestamp" \
      '{issue: $issue, branch: $branch, base: $base, outcome: $outcome, exit_code: $exit_code, duration_seconds: $duration, timestamp: $ts}')"
  elif [[ "$claude_exit" -eq 0 ]]; then
    outcome="exit_clean_no_review"
    linear_add_label "$issue_id" "$RALPH_FAILED_LABEL"
    _taint_descendants "$issue_id"
    record="$(jq -n \
      --arg issue "$issue_id" \
      --arg branch "$branch" \
      --arg base "$base_out" \
      --arg outcome "$outcome" \
      --argjson exit_code "$claude_exit" \
      --argjson duration "$duration" \
      --arg ts "$timestamp" \
      '{issue: $issue, branch: $branch, base: $base, outcome: $outcome, exit_code: $exit_code, duration_seconds: $duration, timestamp: $ts}')"
  else
    outcome="failed"
    linear_add_label "$issue_id" "$RALPH_FAILED_LABEL"
    _taint_descendants "$issue_id"
    record="$(jq -n \
      --arg issue "$issue_id" \
      --arg branch "$branch" \
      --arg base "$base_out" \
      --arg outcome "$outcome" \
      --argjson exit_code "$claude_exit" \
      --argjson duration "$duration" \
      --arg ts "$timestamp" \
      '{issue: $issue, branch: $branch, base: $base, outcome: $outcome, exit_code: $exit_code, duration_seconds: $duration, timestamp: $ts}')"
  fi

  _progress_append "$record"
done
