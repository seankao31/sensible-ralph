#!/usr/bin/env bash
set -euo pipefail

# Config loader: parse config.json with jq, export RALPH_* env vars.
# Usage: source scripts/lib/config.sh /path/to/config.json
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

  local entry var_name json_key value
  for entry in "${keys[@]}"; do
    var_name="${entry%%:*}"
    json_key="${entry##*:}"

    # jq returns literal "null" when the key is absent
    value="$(jq -r --arg k "$json_key" 'if has($k) then .[$k] else "null" end' "$config_file")"

    if [[ "$value" == "null" ]]; then
      echo "config: missing required key '$json_key'" >&2
      return 1
    fi

    # Empty string is allowed; callers validate domain constraints.
    # printf -v handles multi-line values safely (declare -gx requires bash 4.2+).
    printf -v "$var_name" '%s' "$value"
    export "$var_name"
  done
}

_config_load "$1"
