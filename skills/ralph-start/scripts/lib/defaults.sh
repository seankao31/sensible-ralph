#!/usr/bin/env bash
# Shell-side defaults for CLAUDE_PLUGIN_OPTION_* env vars.
#
# The Claude Code plugin harness is supposed to export these values from the
# plugin's userConfig (declared in .claude-plugin/plugin.json) into every
# subprocess it launches. In practice we've seen the values not populated —
# e.g. when a user installs the plugin and never walks through the enable-
# time config dialog (all fields are optional, so the dialog may be skipped
# entirely), settings.json stays empty and the env vars never get set. That
# leaves downstream scripts reading empty strings, which breaks every
# state-name comparison.
#
# '= default' (no leading colon) assigns the fallback AND exports it only
# when the var is entirely UNSET. An explicitly-empty value from the caller
# is preserved — that's caller error we want preflight_labels_check to
# catch, not a state to paper over.
#
# The defaults mirror the plugin.json userConfig defaults — update in lockstep.
# Source from every entry-point script before using any CLAUDE_PLUGIN_OPTION_*
# value. Safe to source multiple times (idempotent).

: "${CLAUDE_PLUGIN_OPTION_APPROVED_STATE=Approved}"
: "${CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE=In Progress}"
: "${CLAUDE_PLUGIN_OPTION_REVIEW_STATE=In Review}"
: "${CLAUDE_PLUGIN_OPTION_DONE_STATE=Done}"
: "${CLAUDE_PLUGIN_OPTION_FAILED_LABEL=ralph-failed}"
: "${CLAUDE_PLUGIN_OPTION_STALE_PARENT_LABEL=stale-parent}"
: "${CLAUDE_PLUGIN_OPTION_WORKTREE_BASE=.worktrees}"
: "${CLAUDE_PLUGIN_OPTION_MODEL=opus}"
: "${CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME=ralph-output.log}"

export CLAUDE_PLUGIN_OPTION_APPROVED_STATE
export CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE
export CLAUDE_PLUGIN_OPTION_REVIEW_STATE
export CLAUDE_PLUGIN_OPTION_DONE_STATE
export CLAUDE_PLUGIN_OPTION_FAILED_LABEL
export CLAUDE_PLUGIN_OPTION_STALE_PARENT_LABEL
export CLAUDE_PLUGIN_OPTION_WORKTREE_BASE
export CLAUDE_PLUGIN_OPTION_MODEL
export CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME
