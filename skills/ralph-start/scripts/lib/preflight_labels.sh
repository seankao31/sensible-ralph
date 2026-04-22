#!/usr/bin/env bash
# Workspace label existence preflight — shared between ralph-start's
# preflight_scan.sh and the `close-feature-branch` skill (ENG-208, which adds
# $RALPH_STALE_PARENT_LABEL). Linear's `issue update --label` silently no-ops
# on a nonexistent label name, so a missing workspace prereq would let
# callers keep "marking" issues with labels that never land. Fail loud.
#
# This file is sourced (not executed); do NOT call `set` at the top level or
# `exit`. Requires `lib/linear.sh` already sourced (provides
# `linear_label_exists`). Requires config already loaded (RALPH_* vars
# exported).
#
# Function:
#   preflight_labels_check — verify each configured label name exists in Linear.
#
# Return:
#   0 — every configured label exists (or the config key is unset/empty).
#   1 — one or more labels are missing, or a query error occurred. Per-label
#       diagnostics are printed to stderr before returning.
#
# Design note: the list of label env vars is hardcoded rather than inferred
# from a RALPH_*_LABEL naming convention. The convention would let any stray
# RALPH_*_LABEL (e.g., a future non-label field named with that suffix)
# accidentally become a label check; an explicit list keeps the set of
# "things that must exist in Linear" auditable.
preflight_labels_check() {
  # Configured-label env vars, in registration order. Add a new entry when a
  # new workflow label is introduced in config.sh (e.g. $RALPH_NEW_LABEL).
  # Values that are unset or empty are skipped — the label is not configured
  # in this workspace's workflow, so its existence is not required here.
  local -a label_vars=(
    RALPH_FAILED_LABEL
    RALPH_STALE_PARENT_LABEL
  )

  local -a missing=()
  local query_failed=0
  local var name rc
  for var in "${label_vars[@]}"; do
    name="${!var:-}"
    [[ -z "$name" ]] && continue

    # `|| rc=$?` both suppresses errexit and captures the rc. Avoids the
    # set +e/set -e dance, which leaks errexit state back to callers that
    # sourced us with errexit off.
    rc=0
    linear_label_exists "$name" || rc=$?

    case "$rc" in
      0) ;;
      1) missing+=("$var=$name") ;;
      *)
        printf 'preflight: failed to query Linear for label %q (configured as %s) — aborting\n' \
          "$name" "$var" >&2
        query_failed=1
        ;;
    esac
  done

  if [[ "$query_failed" -ne 0 ]]; then
    return 1
  fi
  if [[ "${#missing[@]}" -gt 0 ]]; then
    # Name both the literal label and the env var that points at it. Operators
    # who renamed a label in config (team convention, color-group migration)
    # need the env var to find the right config key; operators running defaults
    # need the literal name to type into `linear label create`. Dropping either
    # leaves one class of operator guessing.
    local entry lv ln
    for entry in "${missing[@]}"; do
      lv="${entry%%=*}"
      ln="${entry#*=}"
      printf 'preflight: workspace label %q (configured as %s) does not exist in Linear. Create it once as a workspace-scoped label, or update config to name an existing label. See agent-config/skills/ralph-start/SKILL.md Prerequisites.\n' \
        "$ln" "$lv" >&2
    done
    return 1
  fi
  return 0
}
