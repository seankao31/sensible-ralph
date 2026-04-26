#!/usr/bin/env bash
# Scope loader: parse <repo>/.ralph.json, export RALPH_PROJECTS (newline-joined).
# Usage: source scripts/lib/scope.sh
#
# Scope lives in a per-repo `.ralph.json` at the repo root and is auto-discovered
# via `git rev-parse --show-toplevel`. Two shapes: {"projects": [...]} (explicit)
# or {"initiative": "name"} (expanded to member projects via Linear on every
# invocation).
#
# Portable between bash 3.2+ and zsh. Callers must source `lib/linear.sh`
# before this file (it defines `linear_list_initiative_projects`, which the
# `.ralph.json` `initiative` expansion path calls). The fail-loud guard at
# `_scope_load` entry catches callers that forget; without the guard, the
# initiative path would emit a late "command not found" that's harder to
# trace than a load-time error.
#
# All callers in this codebase run with `set -euo pipefail` already active;
# this file must NOT call `set` at the top level, as sourcing a file with
# top-level `set` commands mutates the caller's shell options.
#
# Exports:
#   RALPH_PROJECTS (newline-joined) — from <repo>/.ralph.json
#   RALPH_DEFAULT_BASE_BRANCH — from .ralph.json `default_base_branch` (default "main")
#   RALPH_SCOPE_LOADED — tuple "<repo-root-abs-path>|<scope-hash>"

# Resolve the working tree root for .ralph.json discovery.
#
# Uses --show-toplevel (not --git-common-dir) so each worktree reads its OWN
# committed .ralph.json. A branch that changes scope is edited in a worktree;
# if this resolved to the main checkout, the worktree would read main's stale
# scope and ignore the edit. This differs from lib/worktree.sh::_resolve_repo_root,
# which uses --git-common-dir because progress.json and the .worktrees/ dir
# are intentionally shared across worktrees.
_scope_resolve_repo_root() {
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
#   - `initiative` resolving to zero projects
_scope_load_projects() {
  local repo_root="$1"
  local scope_file="$repo_root/.ralph.json"

  if [[ ! -f "$scope_file" ]]; then
    echo "scope: .ralph.json not found at '$scope_file' — create it with {\"projects\": [...]} or {\"initiative\": \"...\"}" >&2
    return 1
  fi

  local has_projects has_initiative
  has_projects="$(jq -r 'has("projects")' "$scope_file")" || {
    echo "scope: failed to parse '$scope_file'" >&2
    return 1
  }
  has_initiative="$(jq -r 'has("initiative")' "$scope_file")"

  if [[ "$has_projects" == "true" && "$has_initiative" == "true" ]]; then
    echo "scope: .ralph.json has both 'projects' and 'initiative' — pick one" >&2
    return 1
  fi

  if [[ "$has_projects" != "true" && "$has_initiative" != "true" ]]; then
    echo "scope: .ralph.json must set either 'projects' or 'initiative'" >&2
    return 1
  fi

  local projects_newline
  if [[ "$has_projects" == "true" ]]; then
    projects_newline="$(jq -r '.projects[]' "$scope_file")"
    if [[ -z "$projects_newline" ]]; then
      echo "scope: .ralph.json 'projects' list is empty" >&2
      return 1
    fi
  else
    # Initiative case — expand via linear_list_initiative_projects (defined
    # in lib/linear.sh, which the caller must source before this file; the
    # _scope_load guard rejects callers that forget).
    local initiative
    initiative="$(jq -r '.initiative' "$scope_file")"
    projects_newline="$(linear_list_initiative_projects "$initiative")" || return 1
    if [[ -z "$projects_newline" ]]; then
      echo "scope: initiative '$initiative' resolves to zero projects" >&2
      return 1
    fi
  fi

  export RALPH_PROJECTS="$projects_newline"

  # Optional `default_base_branch`: the trunk ralph branches from when an
  # Approved issue has no in-review parent. Absent → "main" (preserves
  # behavior for every existing .ralph.json). Empty string and non-string
  # JSON types are hard errors caught here, never at git-ref resolution.
  local default_base dbb_type
  dbb_type="$(jq -r 'if has("default_base_branch") then (.default_base_branch | type) else "absent" end' "$scope_file")"
  if [[ "$dbb_type" == "absent" ]]; then
    default_base="main"
  elif [[ "$dbb_type" == "string" ]]; then
    default_base="$(jq -r '.default_base_branch' "$scope_file")"
    if [[ -z "$default_base" ]]; then
      echo "scope: .ralph.json default_base_branch is empty — omit the key or set a non-empty string" >&2
      return 1
    fi
  else
    echo "scope: .ralph.json default_base_branch must be a string, got $dbb_type" >&2
    return 1
  fi
  export RALPH_DEFAULT_BASE_BRANCH="$default_base"
}

_scope_load() {
  # lib/linear.sh must be sourced by the caller before this file — it
  # defines linear_list_initiative_projects, which _scope_load_projects calls
  # for the .ralph.json `initiative` shape. Fail loudly at load time so
  # callers get a clear message rather than a late "command not found"
  # during scope expansion.
  if ! declare -f linear_list_initiative_projects >/dev/null; then
    echo "scope: source lib/linear.sh before lib/scope.sh (defines linear_list_initiative_projects)" >&2
    return 1
  fi

  local repo_root
  repo_root="$(_scope_resolve_repo_root)" || {
    echo "scope: could not resolve repo root (not in a git repo?)" >&2
    return 1
  }

  _scope_load_projects "$repo_root" || return 1

  # Marker tuple: entry-point scripts re-source scope.sh when either the
  # repo root or the .ralph.json content hash changes. Content-hashing
  # catches in-place edits (or branch switches in the same worktree that
  # change scope) — without it, the gate would trust the loaded
  # RALPH_PROJECTS across a scope change with no signal.
  local scope_hash
  scope_hash="$(shasum -a 1 < "$repo_root/.ralph.json" | awk '{print $1}')"
  export RALPH_SCOPE_LOADED="${repo_root}|${scope_hash}"
}

_scope_load
