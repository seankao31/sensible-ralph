#!/usr/bin/env bats
# Tests for skills/sr-status/scripts/render_status.sh — the read-only
# /sr-status renderer. Uses a real throwaway git repo and writes synthetic
# progress.json + ordered_queue.txt fixtures.
#
# ENG-287: ordered_queue.txt always carries a `# run_id: <iso>` header on
# line 1; the renderer reads it directly and partitions progress.json
# records by that run_id. The chronological-sort derivation on
# progress.json is gone.

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

# Helper: write ordered_queue.txt with the `# run_id: <id>` header on line 1
# and the supplied issue IDs on subsequent lines. In production this is
# only ever written by the orchestrator's commitment publish; tests write it
# directly to set up rendered-state fixtures.
# Usage: write_queue <run_id> [issue_id...]
write_queue() {
  local run_id="$1"; shift
  : > "$REPO_DIR/.sensible-ralph/ordered_queue.txt"
  printf '# run_id: %s\n' "$run_id" >> "$REPO_DIR/.sensible-ralph/ordered_queue.txt"
  for id in "$@"; do
    printf '%s\n' "$id" >> "$REPO_DIR/.sensible-ralph/ordered_queue.txt"
  done
}

# ---------------------------------------------------------------------------
# 1. No queue file: friendly hint, exit 0 (legitimate fresh-repo path —
#    no orchestrator run has ever committed a queue here).
# ---------------------------------------------------------------------------
@test "no queue file: prints 'No ralph runs recorded' hint and exits 0" {
  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"No ralph runs recorded"* ]]
  [[ "$output" == *"/sr-start"* ]]
}

# ---------------------------------------------------------------------------
# 2. Single in-flight issue (start record only) — Running with elapsed
# ---------------------------------------------------------------------------
@test "single in-flight issue (start record only): renders under Running with elapsed time" {
  # Start record from 2 minutes ago — elapsed should render as "2m"
  local now_iso; now_iso="$(date -u -v -2M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_progress '[
    {"event":"start","issue":"ENG-211","branch":"eng-211-foo","base":"main","timestamp":"'"$now_iso"'","run_id":"'"$now_iso"'"}
  ]'
  write_queue "$now_iso" ENG-211

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
# 3. Mixed Done + Running + Queued — all three sections populated correctly
# ---------------------------------------------------------------------------
@test "mixed Done + Running + Queued: all sections populated, Done from end record, Running from start record, Queued from queue file" {
  local now_iso; now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local run_id="$now_iso"
  write_progress '[
    {"event":"start","issue":"ENG-208","branch":"eng-208-foo","base":"main","timestamp":"2026-04-22T17:50:00Z","run_id":"'"$run_id"'"},
    {"event":"end","issue":"ENG-208","outcome":"in_review","branch":"eng-208-foo","base":"main","exit_code":0,"duration_seconds":3120,"timestamp":"2026-04-22T17:50:00Z","run_id":"'"$run_id"'"},
    {"event":"start","issue":"ENG-211","branch":"eng-211-bar","base":"main","timestamp":"'"$now_iso"'","run_id":"'"$run_id"'"}
  ]'
  write_queue "$run_id" ENG-208 ENG-211 ENG-212 ENG-213

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
# 4. All complete — Done populated, Running and Queued each show (none)
# ---------------------------------------------------------------------------
@test "all complete: Running and Queued each show (none)" {
  local run_id="2026-04-22T18:30:00Z"
  write_progress '[
    {"event":"start","issue":"ENG-208","branch":"eng-208-foo","base":"main","timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'"},
    {"event":"end","issue":"ENG-208","outcome":"in_review","branch":"eng-208-foo","base":"main","exit_code":0,"duration_seconds":600,"timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'"}
  ]'
  write_queue "$run_id" ENG-208

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
# 5. Failed outcome formatting: 'failed (exit 7)'
# ---------------------------------------------------------------------------
@test "failed outcome: rendered as 'failed (exit N)'" {
  local run_id="2026-04-22T18:30:00Z"
  write_progress '[
    {"event":"start","issue":"ENG-210","branch":"eng-210-foo","base":"main","timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'"},
    {"event":"end","issue":"ENG-210","outcome":"failed","branch":"eng-210-foo","base":"main","exit_code":7,"duration_seconds":180,"timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'"}
  ]'
  write_queue "$run_id" ENG-210

  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed (exit 7)"* ]]
}

# ---------------------------------------------------------------------------
# 6. setup_failed outcome formatting: 'setup_failed (linear_set_state)'
# ---------------------------------------------------------------------------
@test "setup_failed outcome: rendered as 'setup_failed (<failed_step>)'" {
  local run_id="2026-04-22T18:30:00Z"
  write_progress '[
    {"event":"end","issue":"ENG-220","outcome":"setup_failed","failed_step":"linear_set_state","timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'"}
  ]'
  write_queue "$run_id" ENG-220

  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"setup_failed (linear_set_state)"* ]]
}

# ---------------------------------------------------------------------------
# 7. ENG-287 regression: queue header `run_id` takes precedence; new run
#    with no progress.json records yet renders empty Done/Running and full
#    Queued. The old derivation would have selected the previous run.
# ---------------------------------------------------------------------------
@test "ENG-287 queue header run_id wins: new run with no records yet, prior run records ignored" {
  local old_run="2026-04-20T10:00:00Z"
  local new_run="2026-04-22T18:30:00Z"
  # progress.json has only OLD-run records.
  write_progress '[
    {"event":"start","issue":"ENG-OLD","branch":"eng-old","base":"main","timestamp":"'"$old_run"'","run_id":"'"$old_run"'"},
    {"event":"end","issue":"ENG-OLD","outcome":"in_review","branch":"eng-old","base":"main","exit_code":0,"duration_seconds":600,"timestamp":"'"$old_run"'","run_id":"'"$old_run"'"}
  ]'
  # Queue header points at the NEW run with three issue IDs.
  write_queue "$new_run" ENG-A ENG-B ENG-C

  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"Run started: $new_run"* ]]
  [[ "$output" == *"=== Done (0) ==="* ]]
  [[ "$output" == *"=== Running (0) ==="* ]]
  [[ "$output" == *"=== Queued (3) ==="* ]]
  [[ "$output" == *"ENG-A"* ]]
  [[ "$output" == *"ENG-B"* ]]
  [[ "$output" == *"ENG-C"* ]]
  # OLD run's records do not appear anywhere — the structural protection
  # `select(.run_id == $run)` drops them.
  [[ "$output" != *"ENG-OLD"* ]]
  [[ "$output" != *"$old_run"* ]]
}

# ---------------------------------------------------------------------------
# 8. ordered_queue.txt exists but has no header line: error and exit non-zero
#    (legacy header-less file from prior plugin versions, or operator
#    hand-edit that wiped the header).
# ---------------------------------------------------------------------------
@test "ordered_queue.txt without header: errors loud, exit non-zero" {
  : > "$REPO_DIR/.sensible-ralph/ordered_queue.txt"
  printf 'ENG-100\nENG-101\n' > "$REPO_DIR/.sensible-ralph/ordered_queue.txt"

  run_render
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing '# run_id: <id>' header line"* ]]
}

# ---------------------------------------------------------------------------
# 9. ENG-287 setup-time gap: queue header is present but progress.json does
#    not exist yet (first `start` record has not landed). Renderer
#    initializes empty record set and continues — Done(0) Running(0)
#    Queued(N) — instead of crashing under set -e.
# ---------------------------------------------------------------------------
@test "ENG-287 queue header present, progress.json missing: Done(0) Running(0) Queued(N), exit 0" {
  local rid="2026-04-22T18:30:00Z"
  write_queue "$rid" ENG-X ENG-Y
  # Explicitly DO NOT write progress.json.
  [ ! -f "$REPO_DIR/.sensible-ralph/progress.json" ]

  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"Run started: $rid"* ]]
  [[ "$output" == *"=== Done (0) ==="* ]]
  [[ "$output" == *"=== Running (0) ==="* ]]
  [[ "$output" == *"=== Queued (2) ==="* ]]
  [[ "$output" == *"ENG-X"* ]]
  [[ "$output" == *"ENG-Y"* ]]
}

# ---------------------------------------------------------------------------
# 10. Not in a git repo: exit 1 with clear message
# ---------------------------------------------------------------------------
@test "not in a git repo: exit 1 with clear message on stderr" {
  local non_git_dir; non_git_dir="$(mktemp -d)"
  run bash -c "cd '$non_git_dir' && '$RENDER_SH'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not inside a git repository"* ]]
  rm -rf "$non_git_dir"
}

# ---------------------------------------------------------------------------
# 11. Queue file with header but no issue IDs: Queued shows (none)
# ---------------------------------------------------------------------------
@test "header-only ordered_queue.txt (no issues): Queued section shows (none)" {
  local run_id="2026-04-22T18:30:00Z"
  write_progress '[
    {"event":"start","issue":"ENG-400","branch":"eng-400","base":"main","timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'"},
    {"event":"end","issue":"ENG-400","outcome":"in_review","branch":"eng-400","base":"main","exit_code":0,"duration_seconds":300,"timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'"}
  ]'
  write_queue "$run_id"

  run_render
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== Queued (0) ==="* ]]
  [[ "$output" == *"(none)"* ]]
}

# ---------------------------------------------------------------------------
# 12. End-only record (failed start-record write): classifies as Done, not Running
# ---------------------------------------------------------------------------
@test "end-only record (no matching start): classifies as Done, NOT Running, NOT Queued" {
  local run_id="2026-04-22T18:30:00Z"
  # ENG-500 has only an end record. Simulates a failed start-record write.
  write_progress '[
    {"event":"end","issue":"ENG-500","outcome":"in_review","branch":"eng-500","base":"main","exit_code":0,"duration_seconds":600,"timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'"}
  ]'
  # Queue file lists ENG-500 — without the Done classification, it would
  # incorrectly land in Queued.
  write_queue "$run_id" ENG-500

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
# override. These tests use a queue file with a header (ENG-287) so the
# renderer reaches the rendering path.
# ---------------------------------------------------------------------------

@test "ENG-308 failed row with hint+transcript+session: full diagnostic sub-block renders" {
  local run_id="2026-04-22T18:30:00Z"
  write_progress '[
    {"event":"end","issue":"ENG-294","outcome":"exit_clean_no_review","branch":"eng-294","base":"main","exit_code":0,"duration_seconds":840,"timestamp":"2026-04-22T18:30:00Z","run_id":"'"$run_id"'","session_id":"abc-123","transcript_path":"/Users/x/.claude/projects/-foo/abc-123.jsonl","worktree_log_path":"/Users/x/repo/.worktrees/eng-294/ralph-output.log","hint":"no implementation commits; context-loss after Skill (using-superpowers) (claude-code#17351)"}
  ]'
  write_queue "$run_id" ENG-294

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
  write_queue "$run_id" ENG-200

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
  write_queue "$run_id" ENG-150

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
  write_queue "$run_id" ENG-160

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
  write_queue "$run_id" ENG-170

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
  write_queue "$run_id" ENG-180

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
  write_queue "$run_id" ENG-190

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
  write_queue "$run_id" ENG-201

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
  write_queue "$now_iso" ENG-205

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
  write_queue "$now_iso" ENG-206

  run_render
  [ "$status" -eq 0 ]
  # Falls back to repo_root + WORKTREE_BASE + branch + STDOUT_LOG_FILENAME.
  [[ "$output" == *"Tip: tail '$REPO_DIR/.worktrees/eng-206-bar/ralph-output.log'"* ]]
}
