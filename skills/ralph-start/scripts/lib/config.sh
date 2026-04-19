#!/usr/bin/env bash
# Config loader: parse config.json with jq, export RALPH_* env vars.
# Usage: source scripts/lib/config.sh /path/to/config.json
#
# All callers in this codebase run with `set -euo pipefail` already active;
# this file must NOT call `set` at the top level, as sourcing a file with
# top-level `set` commands mutates the caller's shell options.
#
# Exports:
#   RALPH_PROJECT, RALPH_APPROVED_STATE, RALPH_REVIEW_STATE,
#   RALPH_FAILED_LABEL, RALPH_WORKTREE_BASE, RALPH_MODEL,
#   RALPH_STDOUT_LOG, RALPH_PROMPT_TEMPLATE

_config_load() {
  local config_file="$1"

  # Map of: RALPH_VAR_NAME → json_key
  local -a keys=(
    "RALPH_PROJECT:project"
    "RALPH_APPROVED_STATE:approved_state"
    "RALPH_REVIEW_STATE:review_state"
    "RALPH_FAILED_LABEL:failed_label"
    "RALPH_WORKTREE_BASE:worktree_base"
    "RALPH_MODEL:model"
    "RALPH_STDOUT_LOG:stdout_log_filename"
    "RALPH_PROMPT_TEMPLATE:prompt_template"
  )

  # Two-pass approach: collect all values first, then export all-or-nothing.
  # This prevents partial RALPH_* exports in the caller's shell when a key
  # is missing mid-loop (which would leave stale values on retry).
  #
  # bash 3.2 (macOS) does not support associative arrays (declare -A), so
  # parallel indexed arrays are used as the local staging store.
  local -a staged_names=()
  local -a staged_values=()

  local entry var_name json_key value
  for entry in "${keys[@]}"; do
    var_name="${entry%%:*}"
    json_key="${entry##*:}"

    # jq returns literal "null" when the key is absent; exits non-zero on parse error
    value="$(jq -r --arg k "$json_key" 'if has($k) then .[$k] else "null" end' "$config_file")" || {
      echo "config: failed to parse config file '$config_file'" >&2
      return 1
    }

    if [[ "$value" == "null" ]]; then
      echo "config: missing required key '$json_key'" >&2
      return 1
    fi

    staged_names+=("$var_name")
    staged_values+=("$value")
  done

  # All keys present — export atomically.
  # Empty string is allowed; callers validate domain constraints.
  # printf -v handles multi-line values safely (declare -gx requires bash 4.2+).
  local i
  for i in "${!staged_names[@]}"; do
    printf -v "${staged_names[$i]}" '%s' "${staged_values[$i]}"
    export "${staged_names[$i]}"
  done
}

_config_load "$1"
