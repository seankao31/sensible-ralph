#!/usr/bin/env bash
# Config loader: parse config.json (workflow fields) and <repo>/.ralph.json
# (scope fields), export RALPH_* env vars.
# Usage: source scripts/lib/config.sh /path/to/config.json
#
# Scope (RALPH_PROJECTS) lives in a per-repo `.ralph.json` at the repo root
# and is auto-discovered via `git rev-parse --git-common-dir`. Workflow fields
# (state names, labels, worktree base, model, log filename) live in the global
# config.json passed as the first argument.
#
# Portable between bash 3.2+ and zsh. Callers must source `lib/linear.sh`
# before this file (it defines `linear_list_initiative_projects`, which the
# `.ralph.json` `initiative` expansion path calls). The fail-loud guard at
# `_config_load` entry catches callers that forget; without the guard, the
# initiative path would emit a late "command not found" that's harder to
# trace than a load-time error.
#
# All callers in this codebase run with `set -euo pipefail` already active;
# this file must NOT call `set` at the top level, as sourcing a file with
# top-level `set` commands mutates the caller's shell options.
#
# Exports:
#   RALPH_APPROVED_STATE, RALPH_IN_PROGRESS_STATE, RALPH_REVIEW_STATE,
#   RALPH_DONE_STATE, RALPH_FAILED_LABEL, RALPH_STALE_PARENT_LABEL,
#   RALPH_WORKTREE_BASE, RALPH_MODEL, RALPH_STDOUT_LOG — from config.json
#   RALPH_PROJECTS (newline-joined) — from <repo>/.ralph.json
#   RALPH_CONFIG_LOADED — tuple "<global-config-abs-path>|<repo-root-abs-path>"

_config_load_workflow() {
  local config_file="$1"

  # Map of: RALPH_VAR_NAME → json_key
  local -a keys=(
    "RALPH_APPROVED_STATE:approved_state"
    "RALPH_IN_PROGRESS_STATE:in_progress_state"
    "RALPH_REVIEW_STATE:review_state"
    "RALPH_DONE_STATE:done_state"
    "RALPH_FAILED_LABEL:failed_label"
    "RALPH_STALE_PARENT_LABEL:stale_parent_label"
    "RALPH_WORKTREE_BASE:worktree_base"
    "RALPH_MODEL:model"
    "RALPH_STDOUT_LOG:stdout_log_filename"
  )

  # Two-pass approach: collect all values first, then export all-or-nothing.
  # This prevents partial RALPH_* exports in the caller's shell when a key
  # is missing mid-loop (which would leave stale values on retry).
  #
  # Staging as NAME=VALUE tuples (rather than parallel indexed arrays) lets
  # us iterate by value — portable between bash and zsh, which disagree on
  # array indexing. Workflow values are single-line jq scalars with no '='
  # inside, so splitting on the first '=' is unambiguous.
  local -a staged=()

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

    staged+=("$var_name=$value")
  done

  # All keys present — export atomically.
  # Empty string is allowed; callers validate domain constraints.
  # printf -v handles multi-line values safely (declare -gx requires bash 4.2+).
  local pair name val
  for pair in "${staged[@]}"; do
    name="${pair%%=*}"
    val="${pair#*=}"
    printf -v "$name" '%s' "$val"
    export "$name"
  done
}

# Resolve the working tree root for .ralph.json discovery.
#
# Uses --show-toplevel (not --git-common-dir) so each worktree reads its OWN
# committed .ralph.json. A branch that changes scope is edited in a worktree;
# if this resolved to the main checkout, the worktree would read main's stale
# scope and ignore the edit. This differs from lib/worktree.sh::_resolve_repo_root,
# which uses --git-common-dir because progress.json and the .worktrees/ dir
# are intentionally shared across worktrees.
_config_resolve_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || return 1
}

# Load <repo>/.ralph.json, validate, export RALPH_PROJECTS (newline-joined).
#
# Validation (all hard errors — no silent fallbacks; .ralph.json missing or
# malformed means the operator is in the wrong repo or forgot to create it):
#   - file missing
#   - both `projects` and `initiative` set
#   - neither set
#   - `projects` empty list
#   - `initiative` present (expansion TODO in follow-up)
_config_load_scope() {
  local repo_root="$1"
  local scope_file="$repo_root/.ralph.json"

  if [[ ! -f "$scope_file" ]]; then
    echo "config: .ralph.json not found at '$scope_file' — create it with {\"projects\": [...]} or {\"initiative\": \"...\"}" >&2
    return 1
  fi

  local has_projects has_initiative
  has_projects="$(jq -r 'has("projects")' "$scope_file")" || {
    echo "config: failed to parse '$scope_file'" >&2
    return 1
  }
  has_initiative="$(jq -r 'has("initiative")' "$scope_file")"

  if [[ "$has_projects" == "true" && "$has_initiative" == "true" ]]; then
    echo "config: .ralph.json has both 'projects' and 'initiative' — pick one" >&2
    return 1
  fi

  if [[ "$has_projects" != "true" && "$has_initiative" != "true" ]]; then
    echo "config: .ralph.json must set either 'projects' or 'initiative'" >&2
    return 1
  fi

  local projects_newline
  if [[ "$has_projects" == "true" ]]; then
    projects_newline="$(jq -r '.projects[]' "$scope_file")"
    if [[ -z "$projects_newline" ]]; then
      echo "config: .ralph.json 'projects' list is empty" >&2
      return 1
    fi
  else
    # Initiative case — expand via linear_list_initiative_projects (defined
    # in lib/linear.sh, which the caller must source before this file; the
    # _config_load guard rejects callers that forget).
    local initiative
    initiative="$(jq -r '.initiative' "$scope_file")"
    projects_newline="$(linear_list_initiative_projects "$initiative")" || return 1
    if [[ -z "$projects_newline" ]]; then
      echo "config: initiative '$initiative' resolves to zero projects" >&2
      return 1
    fi
  fi

  export RALPH_PROJECTS="$projects_newline"
}

_config_load() {
  local config_file="$1"

  # lib/linear.sh must be sourced by the caller before this file — it
  # defines linear_list_initiative_projects, which _config_load_scope calls
  # for the .ralph.json `initiative` shape. Fail loudly at load time so
  # callers get a clear message rather than a late "command not found"
  # during scope expansion.
  if ! declare -f linear_list_initiative_projects >/dev/null; then
    echo "config: source lib/linear.sh before lib/config.sh (defines linear_list_initiative_projects)" >&2
    return 1
  fi

  _config_load_workflow "$config_file" || return 1

  local repo_root
  repo_root="$(_config_resolve_repo_root)" || {
    echo "config: could not resolve repo root (not in a git repo?)" >&2
    return 1
  }

  _config_load_scope "$repo_root" || return 1

  # Tuple marker: entry-point scripts re-source when any of the three differ.
  # The .ralph.json content hash catches in-place edits (or branch switches
  # in the same worktree that change scope) — without it, the gate would
  # trust the loaded RALPH_PROJECTS across a scope change with no signal.
  local resolved_config scope_hash
  resolved_config="$(cd "$(dirname "$config_file")" && pwd)/$(basename "$config_file")"
  scope_hash="$(shasum -a 1 < "$repo_root/.ralph.json" | awk '{print $1}')"
  export RALPH_CONFIG_LOADED="${resolved_config}|${repo_root}|${scope_hash}"
}

_config_load "$1"
