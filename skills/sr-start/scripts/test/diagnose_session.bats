#!/usr/bin/env bats
# Tests for skills/sr-start/scripts/diagnose_session.sh — pure helper that
# emits a one-line diagnostic hint for non-success autonomous sessions.
#
# Each test sets up a real throwaway git repo as the worktree and points the
# helper at fixture JSONL files under fixtures/diagnose/.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DIAGNOSE_SH="$SCRIPT_DIR/diagnose_session.sh"
FIXTURES="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/diagnose" && pwd)"

setup() {
  WT_DIR="$(cd "$(mktemp -d)" && pwd -P)"
  export WT_DIR
  git -C "$WT_DIR" init -b main -q
  git -C "$WT_DIR" config user.email "t@t.com"
  git -C "$WT_DIR" config user.name "t"
  git -C "$WT_DIR" commit --allow-empty -m "init" -q
  BASE_SHA="$(git -C "$WT_DIR" rev-parse HEAD)"
  export BASE_SHA

  # Transcript lives outside the worktree (mirrors real layout where
  # ~/.claude/projects/<slug>/<session_id>.jsonl is independent of the
  # repo). Putting JSONL inside $WT_DIR would dirty the tree and
  # accidentally trigger H2.
  TRANSCRIPT_DIR="$(cd "$(mktemp -d)" && pwd -P)"
  export TRANSCRIPT_DIR
}

teardown() {
  rm -rf "$WT_DIR" "$TRANSCRIPT_DIR"
}

# ---------------------------------------------------------------------------
# H1 / H2 cases (git-only, no JSONL needed)
# ---------------------------------------------------------------------------

@test "1. empty branch (no commits past base): H1 fires alone" {
  # Worktree is at base; clean tree; no JSONL — pass missing path.
  run "$DIAGNOSE_SH" failed "$WT_DIR" "$BASE_SHA" "$TRANSCRIPT_DIR/no-such.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "no implementation commits" ]
}

@test "2. commits + clean tree: no hints (empty stdout)" {
  echo "x" > "$WT_DIR/a.txt"
  git -C "$WT_DIR" add a.txt
  git -C "$WT_DIR" commit -m "impl" -q

  run "$DIAGNOSE_SH" failed "$WT_DIR" "$BASE_SHA" "$TRANSCRIPT_DIR/no-such.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "3. commits + dirty tree: H2 fires alone" {
  echo "x" > "$WT_DIR/a.txt"
  git -C "$WT_DIR" add a.txt
  git -C "$WT_DIR" commit -m "impl" -q
  echo "uncommitted" > "$WT_DIR/b.txt"

  run "$DIAGNOSE_SH" failed "$WT_DIR" "$BASE_SHA" "$TRANSCRIPT_DIR/no-such.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "uncommitted edits left in worktree" ]
}

@test "4. empty branch + dirty tree: H1 + H2 composed" {
  echo "uncommitted" > "$WT_DIR/b.txt"

  run "$DIAGNOSE_SH" failed "$WT_DIR" "$BASE_SHA" "$TRANSCRIPT_DIR/no-such.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "no implementation commits; uncommitted edits left in worktree" ]
}

# ---------------------------------------------------------------------------
# H2 — orchestrator-owned files are filtered before firing
# ---------------------------------------------------------------------------

@test "H2 filters orchestrator-owned files: ralph-output.log + .sensible-ralph-base-sha alone do not fire" {
  echo "x" > "$WT_DIR/a.txt"
  git -C "$WT_DIR" add a.txt
  git -C "$WT_DIR" commit -m "impl" -q

  # Both orchestrator-owned files appear untracked in the worktree — these are
  # normal artifacts of dispatch and must not trigger H2.
  echo "$BASE_SHA" > "$WT_DIR/.sensible-ralph-base-sha"
  echo "log line" > "$WT_DIR/ralph-output.log"

  run "$DIAGNOSE_SH" failed "$WT_DIR" "$BASE_SHA" "$TRANSCRIPT_DIR/no-such.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "H2 honors CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME override (custom log filename filtered)" {
  echo "x" > "$WT_DIR/a.txt"
  git -C "$WT_DIR" add a.txt
  git -C "$WT_DIR" commit -m "impl" -q

  # Operator overrode the log filename.
  echo "$BASE_SHA" > "$WT_DIR/.sensible-ralph-base-sha"
  echo "log" > "$WT_DIR/custom.log"

  CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME="custom.log" \
    run "$DIAGNOSE_SH" failed "$WT_DIR" "$BASE_SHA" "$TRANSCRIPT_DIR/no-such.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# H3 — JSONL-driven heuristic
# ---------------------------------------------------------------------------

@test "5. JSONL with last turn = Skill + brief text, outcome=failed: H3 fires" {
  # Worktree has commits + clean tree → only H3 should fire.
  echo "x" > "$WT_DIR/a.txt"
  git -C "$WT_DIR" add a.txt
  git -C "$WT_DIR" commit -m "impl" -q

  cp "$FIXTURES/skill-context-loss.jsonl" "$TRANSCRIPT_DIR/transcript.jsonl"
  run "$DIAGNOSE_SH" failed "$WT_DIR" "$BASE_SHA" "$TRANSCRIPT_DIR/transcript.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "context-loss after Skill (using-superpowers) (claude-code#17351)" ]
}

@test "6. same JSONL with outcome=unknown_post_state: H3 suppressed" {
  echo "x" > "$WT_DIR/a.txt"
  git -C "$WT_DIR" add a.txt
  git -C "$WT_DIR" commit -m "impl" -q

  cp "$FIXTURES/skill-context-loss.jsonl" "$TRANSCRIPT_DIR/transcript.jsonl"
  run "$DIAGNOSE_SH" unknown_post_state "$WT_DIR" "$BASE_SHA" "$TRANSCRIPT_DIR/transcript.jsonl"
  [ "$status" -eq 0 ]
  # H1+H2 would not fire (commits + clean), and H3 is suppressed for this outcome.
  [ -z "$output" ]
}

@test "7. outcome=in_review: helper still accepts arg but produces no output" {
  echo "x" > "$WT_DIR/a.txt"
  git -C "$WT_DIR" add a.txt
  git -C "$WT_DIR" commit -m "impl" -q

  cp "$FIXTURES/skill-context-loss.jsonl" "$TRANSCRIPT_DIR/transcript.jsonl"
  run "$DIAGNOSE_SH" in_review "$WT_DIR" "$BASE_SHA" "$TRANSCRIPT_DIR/transcript.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "8. missing JSONL, outcome=failed: H3 silently skipped after bounded poll" {
  echo "x" > "$WT_DIR/a.txt"
  git -C "$WT_DIR" add a.txt
  git -C "$WT_DIR" commit -m "impl" -q

  # Path doesn't exist → bounded poll exhausts → H3 suppresses silently.
  run "$DIAGNOSE_SH" failed "$WT_DIR" "$BASE_SHA" "$TRANSCRIPT_DIR/no-such.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "9. malformed JSONL, outcome=failed: H3 silently skipped" {
  echo "x" > "$WT_DIR/a.txt"
  git -C "$WT_DIR" add a.txt
  git -C "$WT_DIR" commit -m "impl" -q

  cp "$FIXTURES/malformed.jsonl" "$TRANSCRIPT_DIR/transcript.jsonl"
  run "$DIAGNOSE_SH" failed "$WT_DIR" "$BASE_SHA" "$TRANSCRIPT_DIR/transcript.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "9b. JSONL appears mid-poll: H3 reads it on a subsequent iteration and fires" {
  echo "x" > "$WT_DIR/a.txt"
  git -C "$WT_DIR" add a.txt
  git -C "$WT_DIR" commit -m "impl" -q

  # Background-create the JSONL after a 500 ms delay (well within the 2 s
  # poll budget). The helper's bounded poll should catch it.
  ( sleep 0.5 && cp "$FIXTURES/skill-context-loss.jsonl" "$TRANSCRIPT_DIR/transcript.jsonl" ) &
  bg_pid=$!

  run "$DIAGNOSE_SH" failed "$WT_DIR" "$BASE_SHA" "$TRANSCRIPT_DIR/transcript.jsonl"
  wait "$bg_pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ "$output" = "context-loss after Skill (using-superpowers) (claude-code#17351)" ]
}

@test "10. RALPH_DIAGNOSE_DEBUG=1 surfaces per-heuristic decisions on stderr (incl. transcript-not-ready note)" {
  # Empty branch + missing JSONL → H1 fires, H3 hits the bounded-poll path.
  RALPH_DIAGNOSE_DEBUG=1 run "$DIAGNOSE_SH" failed "$WT_DIR" "$BASE_SHA" "$TRANSCRIPT_DIR/no-such.jsonl"
  [ "$status" -eq 0 ]
  # Stdout still carries the H1 hint.
  [[ "$output" == *"no implementation commits"* ]]
  # Stderr surfaces the transcript-not-ready message.
  [[ "$output" == *"H3: transcript_path not ready"* ]] || \
    [[ "$stderr" == *"H3: transcript_path not ready"* ]]
}

@test "implementation-succeeded JSONL (last turn has tool_use): H3 does not fire" {
  echo "x" > "$WT_DIR/a.txt"
  git -C "$WT_DIR" add a.txt
  git -C "$WT_DIR" commit -m "impl" -q

  cp "$FIXTURES/implementation-succeeded.jsonl" "$TRANSCRIPT_DIR/transcript.jsonl"
  run "$DIAGNOSE_SH" failed "$WT_DIR" "$BASE_SHA" "$TRANSCRIPT_DIR/transcript.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# spec_base_sha edge cases
# ---------------------------------------------------------------------------

@test "11. invalid spec_base_sha (well-formed but unknown SHA): H1 suppressed, H2 still runs" {
  echo "uncommitted" > "$WT_DIR/x.txt"

  local bogus="0000000000000000000000000000000000000000"
  run "$DIAGNOSE_SH" failed "$WT_DIR" "$bogus" "$TRANSCRIPT_DIR/no-such.jsonl"
  [ "$status" -eq 0 ]
  # H1 suppressed; H2 fires alone.
  [ "$output" = "uncommitted edits left in worktree" ]
}

@test "12. empty spec_base_sha: H1 suppressed without git cat-file, H2 + H3 still run" {
  echo "uncommitted" > "$WT_DIR/x.txt"
  cp "$FIXTURES/skill-context-loss.jsonl" "$TRANSCRIPT_DIR/transcript.jsonl"

  run "$DIAGNOSE_SH" failed "$WT_DIR" "" "$TRANSCRIPT_DIR/transcript.jsonl"
  [ "$status" -eq 0 ]
  # H1 suppressed; H2 fires; H3 fires.
  [ "$output" = "uncommitted edits left in worktree; context-loss after Skill (using-superpowers) (claude-code#17351)" ]
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "argument validation: missing all args -> non-zero exit, error to stderr" {
  run "$DIAGNOSE_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected 4 args"* ]]
}

@test "argument validation: unknown outcome -> non-zero exit, error names the field" {
  run "$DIAGNOSE_SH" bogus_outcome "$WT_DIR" "$BASE_SHA" "$TRANSCRIPT_DIR/transcript.jsonl"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown outcome"* ]]
}

@test "argument validation: empty worktree_path -> non-zero exit" {
  run "$DIAGNOSE_SH" failed "" "$BASE_SHA" "$TRANSCRIPT_DIR/transcript.jsonl"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required arg worktree_path"* ]]
}

@test "argument validation: empty transcript_path -> non-zero exit" {
  run "$DIAGNOSE_SH" failed "$WT_DIR" "$BASE_SHA" ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required arg transcript_path"* ]]
}
