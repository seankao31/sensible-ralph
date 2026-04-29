#!/usr/bin/env bats
# Tests for skills/sr-status/scripts/render_status.sh — the read-only
# /sr-status renderer. Uses a real throwaway git repo and writes synthetic
# progress.json + ordered_queue.txt fixtures.

# Project root containing skills/sr-start and skills/sr-status.
# The renderer sources $CLAUDE_PLUGIN_ROOT/skills/sr-start/scripts/lib/...,
# so we point CLAUDE_PLUGIN_ROOT at the project root.
PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../../.." && pwd)"
RENDER_SH="$PLUGIN_ROOT/skills/sr-status/scripts/render_status.sh"

setup() {
  REPO_DIR="$(cd "$(mktemp -d)" && pwd -P)"
  export REPO_DIR
  git -C "$REPO_DIR" init -b main -q
  git -C "$REPO_DIR" config user.email "t@t.com"
  git -C "$REPO_DIR" config user.name "t"
  git -C "$REPO_DIR" commit --allow-empty -m "init" -q

  mkdir -p "$REPO_DIR/.sensible-ralph"

  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  # Defaults — the renderer also sources defaults.sh, but exporting here
  # makes the env explicit for assertions on the Tip line.
  export CLAUDE_PLUGIN_OPTION_WORKTREE_BASE=".worktrees"
  export CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME="ralph-output.log"
}

teardown() {
  rm -rf "$REPO_DIR"
}

# Run the renderer from inside the test repo. The renderer resolves the repo
# root via _resolve_repo_root, so cwd just needs to be inside the repo.
run_render() {
  run bash -c "cd '$REPO_DIR' && '$RENDER_SH'"
}

# Helper: write a progress.json fixture from a JSON literal.
write_progress() {
  printf '%s' "$1" > "$REPO_DIR/.sensible-ralph/progress.json"
}

write_queue() {
  : > "$REPO_DIR/.sensible-ralph/ordered_queue.txt"
  for id in "$@"; do
    printf '%s\n' "$id" >> "$REPO_DIR/.sensible-ralph/ordered_queue.txt"
  done
}

# ---------------------------------------------------------------------------
# 5. No progress.json: friendly hint, exit 0
# ---------------------------------------------------------------------------
@test "no progress.json: prints 'No ralph runs recorded' hint and exits 0" {
  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"No ralph runs recorded"* ]]
  [[ "$output" == *"/sr-start"* ]]
}

# ---------------------------------------------------------------------------
# 6. Single in-flight issue (start record only) — Running with elapsed
# ---------------------------------------------------------------------------
@test "single in-flight issue (start record only): renders under Running with elapsed time" {
  # Start record from 2 minutes ago — elapsed should render as "2m"
  local now_iso; now_iso="$(date -u -v -2M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_progress '[
    {"event":"start","issue":"ENG-211","branch":"eng-211-foo","base":"main","timestamp":"'"$now_iso"'","run_id":"'"$now_iso"'"}
  ]'
  write_queue ENG-211

  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== Done (0) ==="* ]]
  [[ "$output" == *"=== Running (1) ==="* ]]
  [[ "$output" == *"ENG-211"* ]]
  [[ "$output" == *"In Progress"* ]]
  # Elapsed time should be 2m (or 1m due to second-level rounding around the boundary)
  [[ "$output" =~ ENG-211[[:space:]]+In\ Progress[[:space:]]+[12]m ]]
  # Tip line uses repo_root-anchored absolute path, recorded branch, shell-quoted
  [[ "$output" == *"Tip: tail '$REPO_DIR/.worktrees/eng-211-foo/ralph-output.log'"* ]]
}

# ---------------------------------------------------------------------------
# 7. Mixed Done + Running + Queued — all three sections populated correctly
# ---------------------------------------------------------------------------
@test "mixed Done + Running + Queued: all sections populated, Done from end record, Running from start record, Queued from queue file" {
  local now_iso; now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local run_id="$now_iso"
  write_progress '[
    {"event":"start","issue":"ENG-208","branch":"eng-208-foo","base":"main","timestamp":"2026-04-22T17:50:00Z","run_id":"'"$run_id"'"},
    {"event":"end","issue":"ENG-208","outcome":"in_review","branch":"eng-208-foo","base":"main","exit_code":0,"duration_seconds":3120,"timestamp":"2026-04-22T17:50:00Z","run_id":"'"$run_id"'"},
    {"event":"start","issue":"ENG-211","branch":"eng-211-bar","base":"main","timestamp":"'"$now_iso"'","run_id":"'"$run_id"'"}
  ]'
  write_queue ENG-208 ENG-211 ENG-212 ENG-213

  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== Done (1) ==="* ]]
  [[ "$output" == *"ENG-208"* ]]
  [[ "$output" == *"in_review"* ]]
  # 3120 seconds = 52 minutes
  [[ "$output" == *"52m"* ]]

  [[ "$output" == *"=== Running (1) ==="* ]]
  [[ "$output" == *"ENG-211"* ]]

  [[ "$output" == *"=== Queued (2) ==="* ]]
  [[ "$output" == *"ENG-212"* ]]
  [[ "$output" == *"ENG-213"* ]]

  [[ "$output" == *"Run started: $run_id"* ]]
}

# ---------------------------------------------------------------------------
# 8. All complete — Done populated, Running and Queued each show (none)
# ---------------------------------------------------------------------------
@test "all complete: Running and Queued each show (none)" {
  local run_id="2026-04-22T18:30:00Z"
  write_progress '[
    {"event":"start","issue":"ENG-208","branch":"eng-208-foo","base":"main","timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'"},
    {"event":"end","issue":"ENG-208","outcome":"in_review","branch":"eng-208-foo","base":"main","exit_code":0,"duration_seconds":600,"timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'"}
  ]'
  write_queue ENG-208

  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== Done (1) ==="* ]]
  [[ "$output" == *"=== Running (0) ==="* ]]
  [[ "$output" == *"=== Queued (0) ==="* ]]

  # Both empty sections show "(none)"
  local none_count; none_count="$(printf '%s\n' "$output" | grep -c '(none)' || true)"
  [ "$none_count" -eq 2 ]
}

# ---------------------------------------------------------------------------
# 9. Failed outcome formatting: 'failed (exit 7)'
# ---------------------------------------------------------------------------
@test "failed outcome: rendered as 'failed (exit N)'" {
  local run_id="2026-04-22T18:30:00Z"
  write_progress '[
    {"event":"start","issue":"ENG-210","branch":"eng-210-foo","base":"main","timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'"},
    {"event":"end","issue":"ENG-210","outcome":"failed","branch":"eng-210-foo","base":"main","exit_code":7,"duration_seconds":180,"timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'"}
  ]'

  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed (exit 7)"* ]]
}

# ---------------------------------------------------------------------------
# 10. setup_failed outcome formatting: 'setup_failed (linear_set_state)'
# ---------------------------------------------------------------------------
@test "setup_failed outcome: rendered as 'setup_failed (<failed_step>)'" {
  local run_id="2026-04-22T18:30:00Z"
  write_progress '[
    {"event":"end","issue":"ENG-220","outcome":"setup_failed","failed_step":"linear_set_state","timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'"}
  ]'

  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"setup_failed (linear_set_state)"* ]]
}

# ---------------------------------------------------------------------------
# 11. Latest run_id selection: only records from the latest run are rendered
# ---------------------------------------------------------------------------
@test "two run_ids in progress.json: only the latest is rendered" {
  local old_run="2026-04-20T10:00:00Z"
  local new_run="2026-04-22T18:30:00Z"
  write_progress '[
    {"event":"start","issue":"ENG-100","branch":"eng-100","base":"main","timestamp":"2026-04-20T10:00:00Z","run_id":"'"$old_run"'"},
    {"event":"end","issue":"ENG-100","outcome":"in_review","branch":"eng-100","base":"main","exit_code":0,"duration_seconds":900,"timestamp":"2026-04-20T10:00:00Z","run_id":"'"$old_run"'"},
    {"event":"start","issue":"ENG-200","branch":"eng-200","base":"main","timestamp":"2026-04-22T18:30:00Z","run_id":"'"$new_run"'"},
    {"event":"end","issue":"ENG-200","outcome":"in_review","branch":"eng-200","base":"main","exit_code":0,"duration_seconds":600,"timestamp":"2026-04-22T18:30:00Z","run_id":"'"$new_run"'"}
  ]'

  run_render
  [ "$status" -eq 0 ]
  # Only the newer run's issue appears
  [[ "$output" == *"ENG-200"* ]]
  [[ "$output" != *"ENG-100"* ]]
  [[ "$output" == *"Run started: $new_run"* ]]
}

# ---------------------------------------------------------------------------
# 12. Legacy pre-event-field records: filtered out by run_id selection
# ---------------------------------------------------------------------------
@test "legacy records (no event field) coexist with new records: legacy filtered out by run_id selection" {
  local legacy_run="2026-04-15T08:00:00Z"
  local new_run="2026-04-22T18:30:00Z"
  # Legacy record has no event field; new run has event:start + event:end.
  write_progress '[
    {"issue":"ENG-50","outcome":"in_review","branch":"eng-50","base":"main","exit_code":0,"duration_seconds":1200,"timestamp":"2026-04-15T08:00:00Z","run_id":"'"$legacy_run"'"},
    {"event":"start","issue":"ENG-300","branch":"eng-300","base":"main","timestamp":"2026-04-22T18:30:00Z","run_id":"'"$new_run"'"},
    {"event":"end","issue":"ENG-300","outcome":"in_review","branch":"eng-300","base":"main","exit_code":0,"duration_seconds":600,"timestamp":"2026-04-22T18:30:00Z","run_id":"'"$new_run"'"}
  ]'

  run_render
  [ "$status" -eq 0 ]
  # Legacy issue does NOT appear (it's in an older run_id)
  [[ "$output" != *"ENG-50"* ]]
  # New issue does appear
  [[ "$output" == *"ENG-300"* ]]
  [[ "$output" == *"Run started: $new_run"* ]]
}

# ---------------------------------------------------------------------------
# 13. Not in a git repo: exit 1 with clear message
# ---------------------------------------------------------------------------
@test "not in a git repo: exit 1 with clear message on stderr" {
  local non_git_dir; non_git_dir="$(mktemp -d)"
  run bash -c "cd '$non_git_dir' && '$RENDER_SH'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not inside a git repository"* ]]
  rm -rf "$non_git_dir"
}

# ---------------------------------------------------------------------------
# 14. Empty ordered_queue.txt: Queued section shows (none)
# ---------------------------------------------------------------------------
@test "empty ordered_queue.txt: Queued section shows (none)" {
  local run_id="2026-04-22T18:30:00Z"
  write_progress '[
    {"event":"start","issue":"ENG-400","branch":"eng-400","base":"main","timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'"},
    {"event":"end","issue":"ENG-400","outcome":"in_review","branch":"eng-400","base":"main","exit_code":0,"duration_seconds":300,"timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'"}
  ]'
  : > "$REPO_DIR/.sensible-ralph/ordered_queue.txt"

  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== Queued (0) ==="* ]]
  [[ "$output" == *"(none)"* ]]
}

# ---------------------------------------------------------------------------
# 15. Out-of-insertion-order run_ids: chronological selection, not array position
# ---------------------------------------------------------------------------
@test "run_ids out of insertion order: chronologically-latest selected via fromdateiso8601" {
  local newest="2026-04-22T18:30:00Z"
  local oldest="2026-03-01T08:00:00Z"
  # The OLDER run_id appears LAST in the array — defeats lexicographic
  # array-position sort but works with explicit fromdateiso8601 sort.
  write_progress '[
    {"event":"start","issue":"ENG-NEW","branch":"eng-new","base":"main","timestamp":"2026-04-22T18:30:00Z","run_id":"'"$newest"'"},
    {"event":"end","issue":"ENG-NEW","outcome":"in_review","branch":"eng-new","base":"main","exit_code":0,"duration_seconds":300,"timestamp":"2026-04-22T18:30:00Z","run_id":"'"$newest"'"},
    {"event":"start","issue":"ENG-OLD","branch":"eng-old","base":"main","timestamp":"2026-03-01T08:00:00Z","run_id":"'"$oldest"'"},
    {"event":"end","issue":"ENG-OLD","outcome":"in_review","branch":"eng-old","base":"main","exit_code":0,"duration_seconds":300,"timestamp":"2026-03-01T08:00:00Z","run_id":"'"$oldest"'"}
  ]'

  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENG-NEW"* ]]
  [[ "$output" != *"ENG-OLD"* ]]
  [[ "$output" == *"Run started: $newest"* ]]
}

# ---------------------------------------------------------------------------
# 16. End-only record (failed start-record write): classifies as Done, not Running
# ---------------------------------------------------------------------------
@test "end-only record (no matching start): classifies as Done, NOT Running, NOT Queued" {
  local run_id="2026-04-22T18:30:00Z"
  # ENG-500 has only an end record. Simulates a failed start-record write.
  write_progress '[
    {"event":"end","issue":"ENG-500","outcome":"in_review","branch":"eng-500","base":"main","exit_code":0,"duration_seconds":600,"timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'"}
  ]'
  # Queue file lists ENG-500 — without the Done classification, it would
  # incorrectly land in Queued.
  write_queue ENG-500

  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== Done (1) ==="* ]]
  [[ "$output" == *"ENG-500"* ]]
  [[ "$output" == *"=== Running (0) ==="* ]]
  [[ "$output" == *"=== Queued (0) ==="* ]]
}

# ---------------------------------------------------------------------------
# ENG-308 session-diagnostics sub-block. Driven by field presence on the end
# record; the only outcome-named rule is the in_review whole-sub-block
# override.
# ---------------------------------------------------------------------------

@test "ENG-308 failed row with hint+transcript+session: full diagnostic sub-block renders" {
  local run_id="2026-04-22T18:30:00Z"
  write_progress '[
    {"event":"end","issue":"ENG-294","outcome":"exit_clean_no_review","branch":"eng-294","base":"main","exit_code":0,"duration_seconds":840,"timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'","session_id":"abc-123","transcript_path":"/Users/x/.claude/projects/-foo/abc-123.jsonl","worktree_log_path":"/Users/x/repo/.worktrees/eng-294/ralph-output.log","hint":"no implementation commits; context-loss after Skill (using-superpowers) (claude-code#17351)"}
  ]'

  run_render
  [ "$status" -eq 0 ]
  # Hint line, leading with the U+21B3 arrow.
  [[ "$output" == *$'\xe2\x86\xb3'" no implementation commits; context-loss after Skill (using-superpowers) (claude-code#17351)"* ]]
  # transcript: line points at the persisted worktree_log_path verbatim.
  [[ "$output" == *"transcript: /Users/x/repo/.worktrees/eng-294/ralph-output.log"* ]]
  # session: line points at the JSONL transcript_path.
  [[ "$output" == *"session: /Users/x/.claude/projects/-foo/abc-123.jsonl"* ]]
}

@test "ENG-308 in_review row with diagnostic fields present: sub-block fully suppressed" {
  local run_id="2026-04-22T18:30:00Z"
  # in_review records DO carry the new fields per the schema, but the
  # whole-sub-block override fires for in_review rows.
  write_progress '[
    {"event":"end","issue":"ENG-200","outcome":"in_review","branch":"eng-200","base":"main","exit_code":0,"duration_seconds":600,"timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'","session_id":"abc-200","transcript_path":"/Users/x/.claude/projects/-foo/abc-200.jsonl","worktree_log_path":"/Users/x/repo/.worktrees/eng-200/ralph-output.log"}
  ]'

  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"in_review"* ]]
  # No sub-block lines.
  [[ "$output" != *$'\xe2\x86\xb3'* ]]
  [[ "$output" != *"transcript: "* ]]
  [[ "$output" != *"session: "* ]]
}

@test "ENG-308 record without new fields (back-compat): row renders one-line, no sub-block" {
  local run_id="2026-04-22T18:30:00Z"
  # No session_id, transcript_path, worktree_log_path, hint — legacy shape.
  write_progress '[
    {"event":"end","issue":"ENG-150","outcome":"failed","branch":"eng-150","base":"main","exit_code":7,"duration_seconds":120,"timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'"}
  ]'

  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed (exit 7)"* ]]
  [[ "$output" != *$'\xe2\x86\xb3'* ]]
  [[ "$output" != *"transcript: "* ]]
  [[ "$output" != *"session: "* ]]
}

@test "ENG-308 record with hint only (no path fields): only the hint line renders" {
  local run_id="2026-04-22T18:30:00Z"
  write_progress '[
    {"event":"end","issue":"ENG-160","outcome":"failed","branch":"eng-160","base":"main","exit_code":1,"duration_seconds":300,"timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'","hint":"no implementation commits"}
  ]'

  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\xe2\x86\xb3'" no implementation commits"* ]]
  # No path lines because the path fields are absent.
  [[ "$output" != *"transcript: "* ]]
  [[ "$output" != *"session: "* ]]
}

@test "ENG-308 record with worktree_log_path only (no hint): only the transcript line renders" {
  local run_id="2026-04-22T18:30:00Z"
  write_progress '[
    {"event":"end","issue":"ENG-170","outcome":"failed","branch":"eng-170","base":"main","exit_code":1,"duration_seconds":300,"timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'","worktree_log_path":"/some/wt/ralph-output.log"}
  ]'

  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"transcript: /some/wt/ralph-output.log"* ]]
  [[ "$output" != *$'\xe2\x86\xb3'* ]]
  [[ "$output" != *"session: "* ]]
}

@test "ENG-308 setup_failed row with no diagnostic fields: stays one-line" {
  local run_id="2026-04-22T18:30:00Z"
  write_progress '[
    {"event":"end","issue":"ENG-180","outcome":"setup_failed","failed_step":"linear_set_state","timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'"}
  ]'

  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"setup_failed (linear_set_state)"* ]]
  [[ "$output" != *$'\xe2\x86\xb3'* ]]
  [[ "$output" != *"transcript: "* ]]
  [[ "$output" != *"session: "* ]]
}

@test "ENG-308 transcript: line uses persisted worktree_log_path verbatim regardless of live config" {
  local run_id="2026-04-22T18:30:00Z"
  # Persisted path uses the OLD configured filename.
  write_progress '[
    {"event":"end","issue":"ENG-190","outcome":"failed","branch":"eng-190","base":"main","exit_code":1,"duration_seconds":300,"timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'","worktree_log_path":"/Users/x/repo/.worktrees/eng-190/old-name.log"}
  ]'

  # Reconfigure the live env vars to a new filename — the renderer must
  # NOT use them for the transcript: line; the persisted path is verbatim.
  CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME="new-name.log" run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"transcript: /Users/x/repo/.worktrees/eng-190/old-name.log"* ]]
  [[ "$output" != *"new-name.log"* ]]
}

@test "ENG-308 unknown_post_state row with full diagnostic fields: sub-block renders the same as failed" {
  local run_id="2026-04-22T18:30:00Z"
  write_progress '[
    {"event":"end","issue":"ENG-201","outcome":"unknown_post_state","branch":"eng-201","base":"main","exit_code":0,"duration_seconds":120,"timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'","session_id":"u-201","transcript_path":"/Users/x/.claude/projects/-foo/u-201.jsonl","worktree_log_path":"/Users/x/repo/.worktrees/eng-201/ralph-output.log","hint":"uncommitted edits left in worktree"}
  ]'

  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"unknown_post_state"* ]]
  [[ "$output" == *$'\xe2\x86\xb3'" uncommitted edits left in worktree"* ]]
  [[ "$output" == *"transcript: /Users/x/repo/.worktrees/eng-201/ralph-output.log"* ]]
  [[ "$output" == *"session: /Users/x/.claude/projects/-foo/u-201.jsonl"* ]]
}

@test "ENG-308 Running tip uses persisted worktree_log_path from start record" {
  local now_iso; now_iso="$(date -u -v -2M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_progress '[
    {"event":"start","issue":"ENG-205","branch":"eng-205-foo","base":"main","timestamp":"'"$now_iso"'","run_id":"'"$now_iso"'","session_id":"r-205","transcript_path":"/Users/x/.claude/projects/-bar/r-205.jsonl","worktree_log_path":"/persisted/worktree/path/dispatch-time.log"}
  ]'

  run_render
  [ "$status" -eq 0 ]
  # Tip uses the persisted path verbatim, not a live-config reconstruction.
  [[ "$output" == *"Tip: tail '/persisted/worktree/path/dispatch-time.log'"* ]]
}

@test "ENG-308 Running tip falls back to live-config reconstruction when start record lacks worktree_log_path" {
  local now_iso; now_iso="$(date -u -v -2M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
  # Legacy start record (pre-ENG-308): no worktree_log_path field.
  write_progress '[
    {"event":"start","issue":"ENG-206","branch":"eng-206-bar","base":"main","timestamp":"'"$now_iso"'","run_id":"'"$now_iso"'"}
  ]'

  run_render
  [ "$status" -eq 0 ]
  # Falls back to repo_root + WORKTREE_BASE + branch + STDOUT_LOG_FILENAME.
  [[ "$output" == *"Tip: tail '$REPO_DIR/.worktrees/eng-206-bar/ralph-output.log'"* ]]
}
