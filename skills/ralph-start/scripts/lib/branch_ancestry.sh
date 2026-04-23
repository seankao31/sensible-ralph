#!/usr/bin/env bash
# Branch-ancestry helpers — pure git, no Linear dependency.
# Used by close-issue's stale-parent check (ENG-208 originally, moved to
# close-issue in ENG-213) and by close-issue's pre-flight branch resolution.
#
# This file is sourced (not executed); do NOT call `set` at the top level or
# `exit`.
#
# Co-located under scripts/lib/ with the Linear helpers because close-issue
# already sources from here. When the ralph-workflow skills consolidate into a
# standalone plugin, these helpers relocate with the rest of the shared
# plumbing — the current location is pragmatic, not principled.
#
# Functions:
#   is_branch_fresh_vs_sha   — 0 fresh, 1 stale, 2 lookup failure
#   list_commits_ahead       — git log parent_sha not-in branch_ref
#   resolve_branch_for_issue — unique local branch matching <issue-slug>-*

# Return 0 if $parent_sha is reachable from $branch_ref (branch is fresh —
# parent's tip is already on its history), 1 if not (branch is structurally
# stale relative to parent), or 2 on any lookup failure (invalid SHA, missing
# ref). Wraps `git merge-base --is-ancestor`, which exits 0/1 for the happy
# path and non-{0,1} for error inputs; the helper normalizes the error space
# to exactly 2 so callers can `case` on three outcomes without interpreting
# git's internal exit codes.
is_branch_fresh_vs_sha() {
  local parent_sha="$1"
  local branch_ref="$2"
  local rc=0
  git merge-base --is-ancestor "$parent_sha" "$branch_ref" 2>/dev/null || rc=$?
  case "$rc" in
    0|1) return "$rc" ;;
    *)
      printf 'is_branch_fresh_vs_sha: merge-base lookup failed for %q %q (git exit %d)\n' \
        "$parent_sha" "$branch_ref" "$rc" >&2
      return 2
      ;;
  esac
}

# Output one line per commit reachable from $parent_sha that is NOT reachable
# from $branch_ref (i.e. commits on the parent that the branch hasn't picked
# up yet). Format matches `git log --oneline`: short SHA + subject, newline-
# terminated. Returns non-zero on lookup failure.
list_commits_ahead() {
  local parent_sha="$1"
  local branch_ref="$2"
  git log --oneline "$branch_ref..$parent_sha" 2>/dev/null || {
    printf 'list_commits_ahead: git log failed for %q..%q\n' "$branch_ref" "$parent_sha" >&2
    return 1
  }
}

# Resolve the local branch for an issue by matching `<issue-slug>-*` where
# issue-slug is the issue ID lowercased. Emit the branch name on stdout and
# exit 0 on a unique match; exit 1 (zero matches) or 2 (multiple matches)
# with a diagnostic on stderr. The two non-zero codes let callers distinguish
# "missing — try fallback" from "ambiguous — stop and ask": the close skill's
# main-issue path falls back to Linear's branchName on exit 1 only, while
# Step 3.5's child walk treats both as "skip with warning."
resolve_branch_for_issue() {
  local issue_id="$1"
  local issue_slug
  issue_slug=$(printf '%s' "$issue_id" | tr '[:upper:]' '[:lower:]')
  local matches
  matches=$(git branch --list "${issue_slug}-*" --format='%(refname:short)')
  local count
  count=$(printf '%s\n' "$matches" | grep -c . || true)

  if [[ "$count" -eq 0 ]]; then
    printf 'resolve_branch_for_issue: no local branch matching %q for issue %s\n' \
      "${issue_slug}-*" "$issue_id" >&2
    return 1
  fi
  if [[ "$count" -gt 1 ]]; then
    printf 'resolve_branch_for_issue: multiple branches match %q for issue %s:\n' \
      "${issue_slug}-*" "$issue_id" >&2
    printf '  %s\n' $matches >&2
    return 2
  fi
  printf '%s\n' "$matches"
}
