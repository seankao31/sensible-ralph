#!/usr/bin/env bash
# close-issue preflight helpers.
# Sourced (not executed); do NOT call `set` or `exit` at top level.
#
# Dependencies (caller must have these in scope before sourcing):
#   - linear_get_issue_state from sr-start's lib/linear.sh
#   - $CLAUDE_PLUGIN_OPTION_REVIEW_STATE
#   - $CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE
#   - $CLAUDE_PLUGIN_OPTION_DONE_STATE
#
# Functions:
#   close_issue_check_review_state — verify the issue is in the review state

# Verify $1's current state matches $CLAUDE_PLUGIN_OPTION_REVIEW_STATE.
# Returns 0 if so. On any other state (or helper failure), returns non-zero
# with a hint message on stderr explaining what to do next.
close_issue_check_review_state() {
  local issue_id="$1"
  local state
  state="$(linear_get_issue_state "$issue_id")" || return 1

  if [ "$state" = "$CLAUDE_PLUGIN_OPTION_REVIEW_STATE" ]; then
    return 0
  fi

  case "$state" in
    "$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE")
      printf '%s is in %s — work has not been handed off for review yet. Run /prepare-for-review first.\n' \
        "$issue_id" "$state" >&2
      ;;
    "$CLAUDE_PLUGIN_OPTION_DONE_STATE")
      printf '%s is already in %s — nothing to do. Investigate whether this worktree is leftover and can be removed.\n' \
        "$issue_id" "$state" >&2
      ;;
    *)
      printf '%s is in %s — dispatch lifecycle is off. Stop and surface to the user.\n' \
        "$issue_id" "$state" >&2
      ;;
  esac
  return 1  # case arms use printf (exit 0); explicit return ensures non-zero for all error paths
}
