#!/usr/bin/env bats
# Tests for skills/close-issue/scripts/lib/stale_parent.sh
# Modeled after skills/sr-start/scripts/test/orchestrator.bats —
# function-level stubbing via STUB_DIR mirrored layout. See linear.bats in
# sr-start for the alternative PATH-stub pattern (used when testing the
# helpers themselves rather than logic that consumes them).
#
# This file uses the STUB_DIR pattern because stale_parent.sh consumes
# linear_label_exists, linear_get_issue_blocks, linear_comment,
# linear_add_label (from lib/linear.sh) and is_branch_fresh_vs_sha,
# list_commits_ahead, resolve_branch_for_issue (from lib/branch_ancestry.sh)
# — we want to drive those helpers' return codes and outputs without going
# through the linear CLI or building real ancestry topologies.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
STALE_PARENT_SH="$SCRIPT_DIR/lib/stale_parent.sh"

# ---------------------------------------------------------------------------
# Setup: STUB_DIR with mirrored lib/ layout containing the real
# stale_parent.sh and fakes for linear.sh + branch_ancestry.sh whose
# behavior is driven by env vars per child id.
# ---------------------------------------------------------------------------
setup() {
  STUB_DIR="$(cd "$(mktemp -d)" && pwd -P)"
  export STUB_DIR

  mkdir -p "$STUB_DIR/lib"
  cp "$STALE_PARENT_SH" "$STUB_DIR/lib/stale_parent.sh"

  # Real temp git repo so `git rev-parse --short "$a_sha"` resolves; cd into
  # it so the (stubbed) ancestry calls and the (real) rev-parse run against
  # this fixture rather than the caller's repo.
  TEST_REPO="$(cd "$(mktemp -d)" && pwd -P)"
  export TEST_REPO
  git -C "$TEST_REPO" init --quiet --initial-branch=main
  git -C "$TEST_REPO" config user.email "t@t.com"
  git -C "$TEST_REPO" config user.name "t"
  git -C "$TEST_REPO" commit --quiet --allow-empty -m "seed"
  cd "$TEST_REPO"
  A_SHA="$(git rev-parse HEAD)"
  export A_SHA

  # Logs the stubs append to so tests can assert "X was commented" /
  # "Y was labeled". Stubs append ONLY on success — mirrors the real-world
  # semantic that a non-zero rc means the mutation didn't take effect.
  export STUB_COMMENT_LOG="$STUB_DIR/comment_log"
  export STUB_LABEL_LOG="$STUB_DIR/label_log"
  : > "$STUB_COMMENT_LOG"
  : > "$STUB_LABEL_LOG"

  # Fake lib/linear.sh.
  #
  # Drivers (env vars; defaults benign):
  #   STUB_LABEL_EXISTS_RC      rc for linear_label_exists       (default 0)
  #   STUB_BLOCKS_JSON          JSON array linear_get_issue_blocks emits
  #                             (default [])
  #   STUB_BLOCKS_RC            rc for linear_get_issue_blocks   (default 0)
  #   STUB_COMMENT_FAIL_<key>   per-child rc for linear_comment
  #   STUB_LABEL_FAIL_<key>     per-child rc for linear_add_label
  #
  # `<key>` = issue id with hyphens converted to underscores (ENG-100 → ENG_100),
  # matching the convention used in sr-start/scripts/test/orchestrator.bats.
  cat > "$STUB_DIR/lib/linear.sh" <<'LINEARSH'
_stub_key() { printf '%s' "$1" | tr '-' '_'; }

linear_label_exists() {
  return "${STUB_LABEL_EXISTS_RC:-0}"
}

linear_get_issue_blocks() {
  if [ "${STUB_BLOCKS_RC:-0}" -ne 0 ]; then
    return "$STUB_BLOCKS_RC"
  fi
  printf '%s' "${STUB_BLOCKS_JSON:-[]}"
}

linear_comment() {
  local child_id="$1" body="$2"
  local key; key="$(_stub_key "$child_id")"
  local fail_var="STUB_COMMENT_FAIL_${key}"
  if [ -n "${!fail_var:-}" ]; then
    return "${!fail_var}"
  fi
  printf '%s\n' "$child_id" >> "$STUB_COMMENT_LOG"
  return 0
}

linear_add_label() {
  local child_id="$1" label="$2"
  local key; key="$(_stub_key "$child_id")"
  local fail_var="STUB_LABEL_FAIL_${key}"
  if [ -n "${!fail_var:-}" ]; then
    return "${!fail_var}"
  fi
  printf '%s|%s\n' "$child_id" "$label" >> "$STUB_LABEL_LOG"
  return 0
}
LINEARSH

  # Fake lib/branch_ancestry.sh.
  #
  # Drivers:
  #   STUB_RESOLVE_RC_<key>  per-child rc for resolve_branch_for_issue
  #   STUB_BRANCH_<key>      per-child branch name (default: id verbatim, so
  #                          the round-trip refs/heads/<branch> → key works)
  #   STUB_FRESH_<key>       per-child rc for is_branch_fresh_vs_sha
  #                          (0 fresh, 1 stale, 2 lookup-failure)
  #   STUB_COMMITS_<key>     per-child stdout for list_commits_ahead
  cat > "$STUB_DIR/lib/branch_ancestry.sh" <<'BRANCHSH'
_stub_key() { printf '%s' "$1" | tr '-' '_'; }

resolve_branch_for_issue() {
  local issue_id="$1"
  local key; key="$(_stub_key "$issue_id")"
  local rc_var="STUB_RESOLVE_RC_${key}"
  local rc="${!rc_var:-0}"
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  local branch_var="STUB_BRANCH_${key}"
  printf '%s' "${!branch_var:-$issue_id}"
}

# Maps the branch_ref BACK to a stub key by stripping refs/heads/. Tests
# rely on the default STUB_BRANCH_<key>=<id> convention so the round-trip
# works without per-test bookkeeping.
is_branch_fresh_vs_sha() {
  local parent_sha="$1" branch_ref="$2"
  local branch="${branch_ref#refs/heads/}"
  local key; key="$(_stub_key "$branch")"
  local fresh_var="STUB_FRESH_${key}"
  return "${!fresh_var:-0}"
}

list_commits_ahead() {
  local parent_sha="$1" branch_ref="$2"
  local branch="${branch_ref#refs/heads/}"
  local key; key="$(_stub_key "$branch")"
  local commits_var="STUB_COMMITS_${key}"
  printf '%s\n' "${!commits_var:-abc1234 stub commit}"
}
BRANCHSH

  # Plugin-harness env vars the function reads. Default REVIEW_STATE matches
  # production; test 7 overrides it.
  export CLAUDE_PLUGIN_OPTION_STALE_PARENT_LABEL="stale-parent"
  export CLAUDE_PLUGIN_OPTION_REVIEW_STATE="In Review"
}

teardown() {
  cd /
  rm -rf "$STUB_DIR" "$TEST_REPO"
}

# ---------------------------------------------------------------------------
# Helper: source the fakes + stale_parent in a subshell, call the function.
#
# Same `if fn; then rc=0; else rc=$?; fi` shape as preflight.bats so the
# CALL_FN_SENTINEL line proves the function used `return` (sentinel
# present) rather than `exit` (sentinel absent — subshell died first).
# Runs under `set -euo pipefail` to mirror close-issue's caller environment.
# ---------------------------------------------------------------------------
call_fn() {
  local fn_name="$1"; shift
  bash -c "set -euo pipefail; source '$STUB_DIR/lib/linear.sh'; source '$STUB_DIR/lib/branch_ancestry.sh'; source '$STUB_DIR/lib/stale_parent.sh'; if $fn_name \"\$@\"; then rc=0; else rc=\$?; fi; echo CALL_FN_SENTINEL; exit \$rc" _ "$@"
}

# ---------------------------------------------------------------------------
# Helper: build a JSON array of {id,state,branch,project} children from
# alternating id/state pairs. Keeps test bodies readable.
#   blocks_json ENG-100 "In Review" ENG-101 "In Progress"
# ---------------------------------------------------------------------------
blocks_json() {
  local entries=""
  while [ "$#" -gt 0 ]; do
    local id="$1" state="$2"; shift 2
    [ -n "$entries" ] && entries+=","
    entries+="{\"id\":\"$id\",\"state\":\"$state\",\"branch\":\"\",\"project\":\"\"}"
  done
  printf '[%s]' "$entries"
}

# ===========================================================================
# 1. Empty A_SHA → silent no-op
# ===========================================================================
@test "close_issue_label_stale_children: empty A_SHA → silent no-op (no helper invoked)" {
  run call_fn close_issue_label_stale_children "ENG-200" ""

  [ "$status" -eq 0 ]
  [ "$output" = "CALL_FN_SENTINEL" ]
  [ ! -s "$STUB_COMMENT_LOG" ]
  [ ! -s "$STUB_LABEL_LOG" ]
}

# ===========================================================================
# 2. No amendments — every child fresh → no labels, no comments, no header
# ===========================================================================
@test "close_issue_label_stale_children: all children fresh → no header, logs empty" {
  export STUB_BLOCKS_JSON
  STUB_BLOCKS_JSON="$(blocks_json ENG-100 "In Review" ENG-101 "In Review" ENG-102 "In Review")"
  export STUB_FRESH_ENG_100=0 STUB_FRESH_ENG_101=0 STUB_FRESH_ENG_102=0

  run call_fn close_issue_label_stale_children "ENG-200" "$A_SHA"

  [ "$status" -eq 0 ]
  [ ! -s "$STUB_COMMENT_LOG" ]
  [ ! -s "$STUB_LABEL_LOG" ]
  if [[ "$output" == *"Step 6 notes"* ]]; then
    echo "expected no Step 6 notes header, got: $output" >&2
    return 1
  fi
}

# ===========================================================================
# 3. Mixed staleness — two stale, one fresh → only stale ones touched
# ===========================================================================
@test "close_issue_label_stale_children: mixed staleness → only stale children commented + labeled" {
  export STUB_BLOCKS_JSON
  STUB_BLOCKS_JSON="$(blocks_json ENG-100 "In Review" ENG-101 "In Review" ENG-102 "In Review")"
  export STUB_FRESH_ENG_100=1 STUB_FRESH_ENG_101=1 STUB_FRESH_ENG_102=0

  run call_fn close_issue_label_stale_children "ENG-200" "$A_SHA"

  [ "$status" -eq 0 ]
  grep -q "^ENG-100$" "$STUB_COMMENT_LOG"
  grep -q "^ENG-101$" "$STUB_COMMENT_LOG"
  ! grep -q "^ENG-102$" "$STUB_COMMENT_LOG"
  grep -q "^ENG-100|stale-parent$" "$STUB_LABEL_LOG"
  grep -q "^ENG-101|stale-parent$" "$STUB_LABEL_LOG"
  ! grep -q "^ENG-102|" "$STUB_LABEL_LOG"
  [[ "$output" == *"applied stale-parent label to 2 child(ren)"* ]]
}

# ===========================================================================
# 4. Workspace label missing → skip everything; no labels, no comments
# ===========================================================================
@test "close_issue_label_stale_children: missing workspace label → skip; no mutations" {
  export STUB_LABEL_EXISTS_RC=1
  export STUB_BLOCKS_JSON
  STUB_BLOCKS_JSON="$(blocks_json ENG-100 "In Review" ENG-101 "In Review")"
  export STUB_FRESH_ENG_100=1 STUB_FRESH_ENG_101=1

  run call_fn close_issue_label_stale_children "ENG-200" "$A_SHA"

  [ "$status" -eq 0 ]
  [ ! -s "$STUB_COMMENT_LOG" ]
  [ ! -s "$STUB_LABEL_LOG" ]
  [[ "$output" == *"workspace label stale-parent does not exist"* ]]
}

# ===========================================================================
# 5. Per-child label failure → comment posted, label NOT applied, "apply
#    manually" hint, summary counts only the fully-succeeding child
# ===========================================================================
@test "close_issue_label_stale_children: per-child label failure → apply-manually hint, summary excludes" {
  export STUB_BLOCKS_JSON
  STUB_BLOCKS_JSON="$(blocks_json ENG-100 "In Review" ENG-101 "In Review")"
  export STUB_FRESH_ENG_100=1 STUB_FRESH_ENG_101=1
  export STUB_LABEL_FAIL_ENG_100=1

  run call_fn close_issue_label_stale_children "ENG-200" "$A_SHA"

  [ "$status" -eq 0 ]
  # Comment posted for both (comment-first, label-second).
  grep -q "^ENG-100$" "$STUB_COMMENT_LOG"
  grep -q "^ENG-101$" "$STUB_COMMENT_LOG"
  # Label applied for ENG-101 only.
  ! grep -q "^ENG-100|" "$STUB_LABEL_LOG"
  grep -q "^ENG-101|stale-parent$" "$STUB_LABEL_LOG"
  # WARN names the failure mode and points to manual application.
  [[ "$output" == *"ENG-100"* ]]
  [[ "$output" == *"label application failed"* ]]
  [[ "$output" == *"apply stale-parent manually"* ]]
  # Summary counts only the fully-succeeding child.
  [[ "$output" == *"applied stale-parent label to 1 child(ren)"* ]]
}

# ===========================================================================
# 6. Blocker-fetch failure → skip; no labels, no comments
# ===========================================================================
@test "close_issue_label_stale_children: linear_get_issue_blocks failure → skip; no mutations" {
  export STUB_BLOCKS_RC=1

  run call_fn close_issue_label_stale_children "ENG-200" "$A_SHA"

  [ "$status" -eq 0 ]
  [ ! -s "$STUB_COMMENT_LOG" ]
  [ ! -s "$STUB_LABEL_LOG" ]
  [[ "$output" == *"could not query outgoing blocks relations"* ]]
}

# ===========================================================================
# 7. CLAUDE_PLUGIN_OPTION_REVIEW_STATE parameterization — only configured-
#    state children are evaluated. Two @test blocks: default and override.
# ===========================================================================
@test "close_issue_label_stale_children: default REVIEW_STATE='In Review' → only In-Review children evaluated" {
  export STUB_BLOCKS_JSON
  STUB_BLOCKS_JSON="$(blocks_json ENG-100 "In Review" ENG-101 "In Progress" ENG-102 "Done")"
  export STUB_FRESH_ENG_100=1 STUB_FRESH_ENG_101=1 STUB_FRESH_ENG_102=1

  run call_fn close_issue_label_stale_children "ENG-200" "$A_SHA"

  [ "$status" -eq 0 ]
  grep -q "^ENG-100$" "$STUB_COMMENT_LOG"
  ! grep -q "^ENG-101$" "$STUB_COMMENT_LOG"
  ! grep -q "^ENG-102$" "$STUB_COMMENT_LOG"
}

@test "close_issue_label_stale_children: override REVIEW_STATE='Reviewing' → only Reviewing children evaluated" {
  export CLAUDE_PLUGIN_OPTION_REVIEW_STATE="Reviewing"
  export STUB_BLOCKS_JSON
  STUB_BLOCKS_JSON="$(blocks_json ENG-100 "In Review" ENG-101 "Reviewing" ENG-102 "Done")"
  export STUB_FRESH_ENG_100=1 STUB_FRESH_ENG_101=1 STUB_FRESH_ENG_102=1

  run call_fn close_issue_label_stale_children "ENG-200" "$A_SHA"

  [ "$status" -eq 0 ]
  ! grep -q "^ENG-100$" "$STUB_COMMENT_LOG"
  grep -q "^ENG-101$" "$STUB_COMMENT_LOG"
  ! grep -q "^ENG-102$" "$STUB_COMMENT_LOG"
}

# ===========================================================================
# 8. Simultaneous failures don't mask each other — comment-fail (rc=1),
#    label-fail (rc=2), and resolve_branch_for_issue (rc=1) each surface a
#    distinct WARN entry; per-child rc cases don't short-circuit the loop.
# ===========================================================================
@test "close_issue_label_stale_children: simultaneous failure modes surface distinct WARN entries" {
  export STUB_BLOCKS_JSON
  STUB_BLOCKS_JSON="$(blocks_json ENG-100 "In Review" ENG-101 "In Review" ENG-102 "In Review")"
  export STUB_FRESH_ENG_100=1 STUB_FRESH_ENG_101=1
  # ENG-100: comment fails → apply_rc=1 → "comment-post failed (no label applied)"
  export STUB_COMMENT_FAIL_ENG_100=1
  # ENG-101: label fails → apply_rc=2 → "comment posted but label application failed"
  export STUB_LABEL_FAIL_ENG_101=1
  # ENG-102: branch resolution fails → "no local branch matching eng-102-* (skipped)"
  export STUB_RESOLVE_RC_ENG_102=1

  run call_fn close_issue_label_stale_children "ENG-200" "$A_SHA"

  [ "$status" -eq 0 ]
  [[ "$output" == *"ENG-100"* ]]
  [[ "$output" == *"comment-post failed"* ]]
  [[ "$output" == *"no label applied"* ]]
  [[ "$output" == *"ENG-101"* ]]
  [[ "$output" == *"label application failed"* ]]
  [[ "$output" == *"ENG-102"* ]]
  [[ "$output" == *"no local branch matching eng-102-*"* ]]
  # Loop didn't short-circuit: ENG-101's label call was attempted (and failed,
  # so the label log is empty). ENG-100's comment call was attempted (and
  # failed, so the comment log only has ENG-101's successful comment).
  grep -q "^ENG-101$" "$STUB_COMMENT_LOG"
  ! grep -q "^ENG-100$" "$STUB_COMMENT_LOG"
  [ ! -s "$STUB_LABEL_LOG" ]
}

# ===========================================================================
# 9. Realistic resolved branch name — freshness stub keys on resolved branch
#    name (not issue id), so STUB_BRANCH_* + STUB_FRESH_<branch_key> must
#    both be set consistently when using non-default names. Verifies the
#    branch-ref handoff between resolve_branch_for_issue and is_branch_fresh_vs_sha.
# ===========================================================================
@test "close_issue_label_stale_children: freshness stub works with realistic resolved branch name" {
  export STUB_BLOCKS_JSON
  STUB_BLOCKS_JSON="$(blocks_json ENG-100 "In Review")"
  # Resolve ENG-100 to a realistic slug (not the issue id itself).
  export STUB_BRANCH_ENG_100="eng-100-some-title"
  # Freshness is keyed on the RESOLVED branch name (hyphens→underscores).
  # When STUB_BRANCH_ENG_100 is set, the stub passes "eng-100-some-title" to
  # is_branch_fresh_vs_sha as refs/heads/eng-100-some-title; stripping
  # refs/heads/ and converting hyphens→underscores via `tr '-' '_'` yields
  # eng_100_some_title (lowercase preserved — _stub_key does NOT uppercase).
  export STUB_FRESH_eng_100_some_title=1  # stale

  run call_fn close_issue_label_stale_children "ENG-200" "$A_SHA"

  [ "$status" -eq 0 ]
  grep -q "^ENG-100$" "$STUB_COMMENT_LOG"
  grep -q "^ENG-100|stale-parent$" "$STUB_LABEL_LOG"
  [[ "$output" == *"applied stale-parent label to 1 child(ren)"* ]]
}

# ===========================================================================
# 10. Caller-variable isolation — working variables (label_rc, blocks_json,
#     children, etc.) must not leak from close_issue_label_stale_children into
#     the caller's shell after invocation. Regression for codex finding:
#     variable leakage is silent (function always returns 0) and can corrupt
#     later steps in a caller shell that reuses the same names.
# ===========================================================================
@test "close_issue_label_stale_children: working variables do not leak into caller scope" {
  export STUB_BLOCKS_JSON
  STUB_BLOCKS_JSON="$(blocks_json ENG-100 "In Review")"
  export STUB_FRESH_ENG_100=1  # stale — exercises the full body path

  run bash -c "
    set -euo pipefail
    source '$STUB_DIR/lib/linear.sh'
    source '$STUB_DIR/lib/branch_ancestry.sh'
    source '$STUB_DIR/lib/stale_parent.sh'

    # Set caller-owned sentinel values for every working variable the function
    # internally uses.
    label_rc=SENTINEL_LABEL_RC
    blocks_json=SENTINEL_BLOCKS
    children=SENTINEL_CHILDREN
    child_id=SENTINEL_CHILD_ID
    resolve_rc=SENTINEL_RESOLVE_RC
    child_branch=SENTINEL_BRANCH
    child_slug=SENTINEL_SLUG
    fresh_rc=SENTINEL_FRESH_RC
    apply_rc=SENTINEL_APPLY_RC

    close_issue_label_stale_children 'ENG-200' '$A_SHA' > /dev/null

    # After return, caller sentinels must be unchanged.
    [ \"\$label_rc\"    = 'SENTINEL_LABEL_RC' ]   || { printf 'label_rc leaked\n'    >&2; exit 1; }
    [ \"\$blocks_json\" = 'SENTINEL_BLOCKS' ]      || { printf 'blocks_json leaked\n' >&2; exit 1; }
    [ \"\$children\"    = 'SENTINEL_CHILDREN' ]    || { printf 'children leaked\n'    >&2; exit 1; }
    [ \"\$child_id\"    = 'SENTINEL_CHILD_ID' ]    || { printf 'child_id leaked\n'    >&2; exit 1; }
    [ \"\$resolve_rc\"  = 'SENTINEL_RESOLVE_RC' ]  || { printf 'resolve_rc leaked\n'  >&2; exit 1; }
    [ \"\$child_branch\" = 'SENTINEL_BRANCH' ]     || { printf 'child_branch leaked\n'>&2; exit 1; }
    [ \"\$child_slug\"  = 'SENTINEL_SLUG' ]        || { printf 'child_slug leaked\n'  >&2; exit 1; }
    [ \"\$fresh_rc\"    = 'SENTINEL_FRESH_RC' ]    || { printf 'fresh_rc leaked\n'    >&2; exit 1; }
    [ \"\$apply_rc\"    = 'SENTINEL_APPLY_RC' ]    || { printf 'apply_rc leaked\n'    >&2; exit 1; }
    echo ISOLATION_OK
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"ISOLATION_OK"* ]]
}
