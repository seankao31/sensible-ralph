#!/usr/bin/env bash
# diagnose_session.sh — emit a one-line diagnostic hint for a non-success
# autonomous session. Pure helper: no Linear writes, no progress.json writes,
# no state mutation. Reads git state and (optionally) the JSONL transcript;
# writes one line to stdout when a heuristic fires, otherwise nothing.
#
# Invocation:
#   diagnose_session.sh <outcome> <worktree_path> <spec_base_sha> <transcript_path>
#
# - <outcome>           one of the seven outcome strings.
# - <worktree_path>     absolute path to the worktree; cwd for git commands.
# - <spec_base_sha>     SHA the orchestrator captured pre-dispatch. Empty
#                       string is a valid value and means "base-sha
#                       unavailable" — H1 silently suppresses.
# - <transcript_path>   absolute path the orchestrator computed for the JSONL
#                       transcript. May not exist on disk; H3 handles missing
#                       and unreadable files defensively.
#
# Output:
#   stdout: zero or one line. When >1 heuristic fires the hints are joined
#           with `; ` in the order H1 → H2 → H3 (git facts first, then JSONL
#           inference). Empty match → no output.
#   stderr: silent at default verbosity. Per-heuristic decisions go to stderr
#           only when RALPH_DIAGNOSE_DEBUG=1.
#   exit:   0 on successful invocation (whether or not any heuristic fired);
#           non-zero on misinvocation (argument-validation failure).
#
# Outcome eligibility (orchestrator decides invocation; helper still no-ops
# when an outcome doesn't apply):
#
#   in_review            n/a — script not invoked
#   exit_clean_no_review H1, H2, H3
#   failed               H1, H2, H3
#   unknown_post_state   H1, H2 only (H3 suppressed)
#   setup_failed         no heuristics run (failed_step is the right diagnostic)
#   local_residue        n/a — script not invoked
#   skipped              n/a — script not invoked

set -uo pipefail

_dbg() {
  [[ "${RALPH_DIAGNOSE_DEBUG:-0}" == "1" ]] || return 0
  printf '%s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------
if [[ $# -ne 4 ]]; then
  printf 'diagnose_session: expected 4 args (outcome worktree_path spec_base_sha transcript_path), got %d\n' "$#" >&2
  exit 2
fi

outcome="$1"
worktree_path="$2"
spec_base_sha="$3"
transcript_path="$4"

case "$outcome" in
  in_review|exit_clean_no_review|failed|setup_failed|local_residue|unknown_post_state|skipped) ;;
  '')
    printf 'diagnose_session: missing required arg outcome\n' >&2
    exit 2
    ;;
  *)
    printf 'diagnose_session: unknown outcome %q\n' "$outcome" >&2
    exit 2
    ;;
esac

if [[ -z "$worktree_path" ]]; then
  printf 'diagnose_session: missing required arg worktree_path\n' >&2
  exit 2
fi

if [[ -z "$transcript_path" ]]; then
  printf 'diagnose_session: missing required arg transcript_path\n' >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Outcome-driven heuristic eligibility
# ---------------------------------------------------------------------------
# Whether each heuristic runs at all. `0` = run, `1` = skip.
h1_eligible=1
h2_eligible=1
h3_eligible=1
case "$outcome" in
  exit_clean_no_review|failed)
    h1_eligible=0
    h2_eligible=0
    h3_eligible=0
    ;;
  unknown_post_state)
    h1_eligible=0
    h2_eligible=0
    ;;
esac

# ---------------------------------------------------------------------------
# H1 — no implementation commits between spec_base_sha and HEAD
# ---------------------------------------------------------------------------
h1_hint=""
if [[ "$h1_eligible" -eq 0 ]]; then
  if [[ -z "$spec_base_sha" ]]; then
    _dbg "H1: spec_base_sha empty — suppressing"
  elif ! git -C "$worktree_path" cat-file -e "${spec_base_sha}^{commit}" 2>/dev/null; then
    _dbg "H1: spec_base_sha=$spec_base_sha not a valid commit — suppressing"
  else
    h1_count="$(git -C "$worktree_path" rev-list "${spec_base_sha}..HEAD" --count 2>/dev/null || printf '')"
    if [[ -z "$h1_count" ]]; then
      _dbg "H1: rev-list failed — suppressing"
    elif [[ "$h1_count" -eq 0 ]]; then
      h1_hint="no implementation commits"
      _dbg "H1: fired — $h1_hint"
    else
      _dbg "H1: $h1_count commits past base — not firing"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# H2 — uncommitted edits left in worktree (excluding orchestrator-owned files)
# ---------------------------------------------------------------------------
h2_hint=""
if [[ "$h2_eligible" -eq 0 ]]; then
  log_filename="${CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME:-ralph-output.log}"
  # Use --porcelain -z (NUL-delimited) so paths are never C-quoted by git.
  # The standard `--porcelain` format C-quotes paths with special characters
  # (spaces, backslashes, non-ASCII), which makes reliable path comparison
  # against `log_filename` unnecessarily complex. The -z form gives us raw
  # bytes with no quoting, which we can compare directly.
  #
  # Format with -z: each record is "<XY><SP><path>\0", so we split on NUL
  # and strip the first 3 bytes (status + space) to get the path.
  remaining=0
  while IFS= read -r -d '' record; do
    [[ -z "$record" ]] && continue
    path="${record:3}"
    [[ "$path" == ".sensible-ralph-base-sha" ]] && continue
    [[ "$path" == "$log_filename" ]] && continue
    remaining=$((remaining + 1))
  done < <(git -C "$worktree_path" status --porcelain -z 2>/dev/null || true)

  if [[ "$remaining" -gt 0 ]]; then
    h2_hint="uncommitted edits left in worktree"
    _dbg "H2: fired — $h2_hint"
  else
    _dbg "H2: clean tree (after filtering orchestrator-owned files)"
  fi
fi

# ---------------------------------------------------------------------------
# H3 — context-loss after Skill (claude-code#17351)
# ---------------------------------------------------------------------------
# Defensive JSONL parsing: read up to the last 5 events whose .type ==
# "assistant"; fire if at least one of those contains a tool_use whose
# .name == "Skill" AND no chronologically-later assistant event in the
# window contains any tool_use.
h3_hint=""
if [[ "$h3_eligible" -eq 0 ]]; then
  # Bounded poll for JSONL readiness — the file may not be flushed at the
  # instant `claude -p` returns. 20 iterations × 100 ms = 2 s budget.
  ready=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if [[ -r "$transcript_path" ]]; then
      ready=1
      break
    fi
    sleep 0.1
  done

  if [[ "$ready" -ne 1 ]]; then
    _dbg "H3: transcript_path not ready after 2s — suppressing"
  else
    # Read the last 5 assistant events, oldest-to-newest within the window.
    # Use jq to pre-filter to assistant lines and tail/head to bound the
    # window. Suppress all jq diagnostics — defensive parsing posture.
    # The `|| true` keeps the script from aborting on parse failure if `-e`
    # is ever added to the set flags; the empty window is then treated as
    # "no assistant events" and H3 suppresses silently (correct behavior).
    assistant_window="$(jq -c 'select(.type == "assistant")' < "$transcript_path" 2>/dev/null \
      | tail -n 5)" || true
    if [[ -z "$assistant_window" ]]; then
      _dbg "H3: no assistant events in transcript — suppressing"
    else
      # Walk the window oldest → newest. Track the most-recent Skill tool_use
      # name; if a later assistant turn carries no tool_use at all, we have
      # the context-loss shape.
      last_skill_idx=-1
      last_skill_name=""
      last_tool_use_idx=-1
      idx=0
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Any tool_use in this assistant event?
        if printf '%s' "$line" | jq -e '.message.content | type == "array" and any(.[]?; .type == "tool_use")' >/dev/null 2>&1; then
          last_tool_use_idx=$idx
          # Was a Skill tool_use among them?
          skill_name="$(printf '%s' "$line" | jq -r '
            .message.content
            | map(select(.type == "tool_use" and .name == "Skill"))
            | (last // {}).input.skill // empty
          ' 2>/dev/null)"
          if [[ -n "$skill_name" ]]; then
            last_skill_idx=$idx
            last_skill_name="$skill_name"
          fi
        fi
        idx=$((idx + 1))
      done <<< "$assistant_window"

      # Fire if a Skill tool_use was seen AND no later assistant turn in the
      # window had any tool_use. The `idx > last_skill_idx + 1` guard is
      # essential: if the Skill turn is the LAST event in the window (idx ==
      # last_skill_idx + 1), we cannot distinguish "agent stopped after Skill"
      # from "agent will call more tools on the next turn" — do NOT fire.
      # The context-loss shape requires a chronologically-later text-only turn
      # to confirm the agent stopped, not just a Skill as the final event.
      if [[ "$last_skill_idx" -ge 0 && "$last_tool_use_idx" -le "$last_skill_idx" && "$idx" -gt $((last_skill_idx + 1)) ]]; then
        if [[ -n "$last_skill_name" ]]; then
          h3_hint="context-loss after Skill (${last_skill_name}) (claude-code#17351)"
        else
          h3_hint="context-loss after Skill (claude-code#17351)"
        fi
        _dbg "H3: fired — $h3_hint"
      else
        _dbg "H3: no context-loss shape (last_skill_idx=$last_skill_idx, last_tool_use_idx=$last_tool_use_idx, window_size=$idx)"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Compose
# ---------------------------------------------------------------------------
hints=()
[[ -n "$h1_hint" ]] && hints+=("$h1_hint")
[[ -n "$h2_hint" ]] && hints+=("$h2_hint")
[[ -n "$h3_hint" ]] && hints+=("$h3_hint")

if [[ "${#hints[@]}" -eq 0 ]]; then
  exit 0
fi

# Join with "; "
out="${hints[0]}"
for (( i = 1; i < ${#hints[@]}; i++ )); do
  out="${out}; ${hints[$i]}"
done
printf '%s\n' "$out"
exit 0
