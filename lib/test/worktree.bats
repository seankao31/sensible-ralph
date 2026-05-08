#!/usr/bin/env bats
# Tests for lib/worktree.sh
# Uses a real throwaway git repo — no mocked git commands.

LIB_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
WORKTREE_SH="$LIB_DIR/worktree.sh"

setup() {
  REPO_DIR="$(cd "$(mktemp -d)" && pwd -P)"
  git -C "$REPO_DIR" init -b main
  git -C "$REPO_DIR" config user.email "test@test.com"
  git -C "$REPO_DIR" config user.name "Test"
  # Create an initial commit so main branch exists
  touch "$REPO_DIR/README.md"
  git -C "$REPO_DIR" add README.md
  git -C "$REPO_DIR" commit -m "init"

  # Export CLAUDE_PLUGIN_OPTION_WORKTREE_BASE as config.sh would
  export CLAUDE_PLUGIN_OPTION_WORKTREE_BASE=".worktrees"
  # ENG-214: worktree_create_with_integration reads the trunk from this var
  # (formerly hardcoded to "main"). In production lib/scope.sh exports it;
  # tests bypass scope-loading so they must export it themselves.
  export SENSIBLE_RALPH_DEFAULT_BASE_BRANCH="main"
}

teardown() {
  rm -rf "$REPO_DIR"
}

# ---------------------------------------------------------------------------
# Helper: source worktree.sh and call a function in a subshell
# ---------------------------------------------------------------------------
call_fn() {
  local fn_name="$1"; shift
  # Run from inside the repo so git commands have a repo context
  bash -c "cd '$REPO_DIR' && source '$WORKTREE_SH' && $fn_name $(printf '%q ' "$@")"
}

# Like call_fn but runs from a caller-specified working directory.
call_fn_from() {
  local cwd="$1" fn_name="$2"; shift 2
  CWD_OVERRIDE="$cwd" bash -c "cd \"\$CWD_OVERRIDE\" && source '$WORKTREE_SH' && $fn_name $(printf '%q ' "$@")"
}

# ---------------------------------------------------------------------------
# 1. worktree_create_at_base — creates a worktree at the given path on a new branch
# ---------------------------------------------------------------------------
@test "worktree_create_at_base creates worktree directory at the given path" {
  local wt_path="$REPO_DIR/.worktrees/feature-abc"

  run call_fn worktree_create_at_base "$wt_path" "feature-abc" "main"

  [ "$status" -eq 0 ]
  [ -d "$wt_path" ]
}

@test "worktree_create_at_base creates worktree on the specified new branch" {
  local wt_path="$REPO_DIR/.worktrees/feature-xyz"

  call_fn worktree_create_at_base "$wt_path" "feature-xyz" "main"

  run git -C "$wt_path" branch --show-current
  [ "$status" -eq 0 ]
  [ "$output" = "feature-xyz" ]
}

@test "worktree_create_at_base accepts base ref present only as remote tracking ref" {
  # Fresh-clone case: a single-parent base (review branch) that was fetched
  # but not checked out as a local head. Codex P1: previously failed because
  # the short name was passed directly to `git worktree add`.
  git -C "$REPO_DIR" checkout -b "eng-60-remote-base"
  echo "remote-base content" > "$REPO_DIR/remote-base.txt"
  git -C "$REPO_DIR" add remote-base.txt
  git -C "$REPO_DIR" commit -m "remote-only base"
  local base_sha; base_sha="$(git -C "$REPO_DIR" rev-parse HEAD)"
  git -C "$REPO_DIR" checkout main -q
  git -C "$REPO_DIR" branch -D "eng-60-remote-base" -q
  git -C "$REPO_DIR" update-ref "refs/remotes/origin/eng-60-remote-base" "$base_sha"

  local wt_path="$REPO_DIR/.worktrees/single-remote-parent"

  run call_fn worktree_create_at_base "$wt_path" "single-remote-parent" "eng-60-remote-base"

  [ "$status" -eq 0 ]
  [ -f "$wt_path/remote-base.txt" ]
}

@test "worktree_create_at_base returns non-zero when base ref is missing entirely" {
  local wt_path="$REPO_DIR/.worktrees/bad-base"

  run call_fn worktree_create_at_base "$wt_path" "bad-base" "nonexistent-branch"

  [ "$status" -ne 0 ]
  [[ "$output" =~ "base ref not found" ]]
  [ ! -d "$wt_path" ]
}

# ---------------------------------------------------------------------------
# 2. worktree_create_with_integration — clean merge brings parent content in
# ---------------------------------------------------------------------------
@test "worktree_create_with_integration merges parent content into worktree" {
  # Create a parent branch with a unique file
  git -C "$REPO_DIR" checkout -b "eng-10-parent"
  echo "parent content" > "$REPO_DIR/parent_file.txt"
  git -C "$REPO_DIR" add parent_file.txt
  git -C "$REPO_DIR" commit -m "add parent file"
  git -C "$REPO_DIR" checkout main

  local wt_path="$REPO_DIR/.worktrees/integration-branch"

  run call_fn worktree_create_with_integration "$wt_path" "integration-branch" "eng-10-parent"

  [ "$status" -eq 0 ]
  [ -d "$wt_path" ]
  [ -f "$wt_path/parent_file.txt" ]
}

# ---------------------------------------------------------------------------
# 3. worktree_create_with_integration — conflict left in-place, not aborted
# ---------------------------------------------------------------------------
@test "worktree_create_with_integration leaves merge conflicts in-place" {
  # Branch from initial commit so both main and parent independently add the same
  # file — this creates an add/add conflict that git cannot auto-resolve.
  git -C "$REPO_DIR" checkout -b "eng-11-conflicting"
  echo "parent version" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "parent adds conflict.txt"
  git -C "$REPO_DIR" checkout main

  echo "main version" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "main adds conflict.txt"

  local wt_path="$REPO_DIR/.worktrees/conflicting-integration"

  # This must NOT fail even though there is a conflict
  run call_fn worktree_create_with_integration "$wt_path" "conflicting-integration" "eng-11-conflicting"

  [ "$status" -eq 0 ]
  [ -d "$wt_path" ]
  # Conflict marker in git status: UU or AA
  run git -C "$wt_path" status --porcelain
  [[ "$output" =~ ^(UU|AA) ]]
}

# ---------------------------------------------------------------------------
# 4. worktree_path_for_issue — computes the correct path from repo root
# ---------------------------------------------------------------------------
@test "worktree_path_for_issue returns correct path for a branch name" {
  local expected="$REPO_DIR/$CLAUDE_PLUGIN_OPTION_WORKTREE_BASE/eng-99-some-feature"

  run call_fn worktree_path_for_issue "eng-99-some-feature"

  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "worktree_path_for_issue strips leading and trailing slashes from CLAUDE_PLUGIN_OPTION_WORKTREE_BASE" {
  local expected="$REPO_DIR/.worktrees/eng-99-slash-test"

  run bash -c "cd '$REPO_DIR' && CLAUDE_PLUGIN_OPTION_WORKTREE_BASE='/.worktrees/' source '$WORKTREE_SH' && worktree_path_for_issue eng-99-slash-test"

  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

# ---------------------------------------------------------------------------
# 5. worktree_path_for_issue — returns non-zero when cwd has no git repo
# ---------------------------------------------------------------------------
@test "worktree_path_for_issue fails when run from a non-git directory" {
  local no_git_dir
  no_git_dir="$(mktemp -d)"

  run call_fn_from "$no_git_dir" worktree_path_for_issue "eng-99-no-git"

  [ "$status" -ne 0 ]

  rm -rf "$no_git_dir"
}

# ---------------------------------------------------------------------------
# 5a. worktree_path_for_issue — must resolve the true repo root even when
#     invoked from inside a linked worktree. `git rev-parse --show-toplevel`
#     returns the calling worktree's own root, which would cause new worktrees
#     to nest at <worktree>/.worktrees/<branch>. The function must anchor off
#     the shared git common dir so the result is the same from any worktree.
# ---------------------------------------------------------------------------
@test "worktree_path_for_issue returns main repo path when invoked from a linked worktree" {
  local linked_wt="$REPO_DIR/.worktrees/existing-wt"
  git -C "$REPO_DIR" worktree add "$linked_wt" -b "existing-wt"

  local expected="$REPO_DIR/$CLAUDE_PLUGIN_OPTION_WORKTREE_BASE/eng-99-new-feature"

  run call_fn_from "$linked_wt" worktree_path_for_issue "eng-99-new-feature"

  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "worktree_path_for_issue returns main repo path when invoked from a subdir of a linked worktree" {
  local linked_wt="$REPO_DIR/.worktrees/existing-wt"
  git -C "$REPO_DIR" worktree add "$linked_wt" -b "existing-wt-subdir"
  mkdir -p "$linked_wt/nested/deep"

  local expected="$REPO_DIR/$CLAUDE_PLUGIN_OPTION_WORKTREE_BASE/eng-99-new-feature"

  run call_fn_from "$linked_wt/nested/deep" worktree_path_for_issue "eng-99-new-feature"

  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

# ---------------------------------------------------------------------------
# 5b. worktree_create_with_integration — accept parent that exists only as
#     a remote-tracking ref (cross-machine usage: branches fetched from origin
#     without local heads). Codex review: the local-heads-only check rejected
#     valid integration parents on fresh clones.
# ---------------------------------------------------------------------------
@test "worktree_create_with_integration accepts parent present only as remote tracking ref" {
  # Build a parent commit, capture its SHA, then synthesize a remote-tracking
  # ref by deleting the local branch and writing refs/remotes/origin/<branch>
  # directly. This mimics the post-fetch state without needing a real remote.
  git -C "$REPO_DIR" checkout -b "eng-50-remote-parent"
  echo "remote-only parent content" > "$REPO_DIR/remote-only.txt"
  git -C "$REPO_DIR" add remote-only.txt
  git -C "$REPO_DIR" commit -m "remote-only parent"
  local parent_sha; parent_sha="$(git -C "$REPO_DIR" rev-parse HEAD)"
  git -C "$REPO_DIR" checkout main -q
  git -C "$REPO_DIR" branch -D "eng-50-remote-parent" -q
  git -C "$REPO_DIR" update-ref "refs/remotes/origin/eng-50-remote-parent" "$parent_sha"

  local wt_path="$REPO_DIR/.worktrees/remote-parent-integration"

  run call_fn worktree_create_with_integration "$wt_path" "remote-parent-integration" "eng-50-remote-parent"

  [ "$status" -eq 0 ]
  [ -f "$wt_path/remote-only.txt" ]
}

# ---------------------------------------------------------------------------
# 6. worktree_create_with_integration — bad parent ref returns non-zero + stderr
# ---------------------------------------------------------------------------
@test "worktree_create_with_integration returns non-zero for a missing parent ref" {
  local wt_path="$REPO_DIR/.worktrees/bad-parent-integration"

  run call_fn worktree_create_with_integration "$wt_path" "bad-parent-integration" "nonexistent-branch"

  [ "$status" -ne 0 ]
  [[ "$output" =~ "parent ref not found" ]]
  # Pre-validation must fire before worktree creation — directory must not exist
  [ ! -d "$wt_path" ]
}

# ---------------------------------------------------------------------------
# 7. worktree_create_with_integration — two parents, content from both present
# ---------------------------------------------------------------------------
@test "worktree_create_with_integration merges content from two parents" {
  # Parent A: adds file-a.txt
  git -C "$REPO_DIR" checkout -b "eng-20-parent-a"
  echo "content from parent A" > "$REPO_DIR/file-a.txt"
  git -C "$REPO_DIR" add file-a.txt
  git -C "$REPO_DIR" commit -m "parent A adds file-a.txt"
  git -C "$REPO_DIR" checkout main

  # Parent B: adds file-b.txt
  git -C "$REPO_DIR" checkout -b "eng-21-parent-b"
  echo "content from parent B" > "$REPO_DIR/file-b.txt"
  git -C "$REPO_DIR" add file-b.txt
  git -C "$REPO_DIR" commit -m "parent B adds file-b.txt"
  git -C "$REPO_DIR" checkout main

  local wt_path="$REPO_DIR/.worktrees/two-parent-integration"

  run call_fn worktree_create_with_integration "$wt_path" "two-parent-integration" "eng-20-parent-a" "eng-21-parent-b"

  [ "$status" -eq 0 ]
  [ -f "$wt_path/file-a.txt" ]
  [ -f "$wt_path/file-b.txt" ]
}

# ---------------------------------------------------------------------------
# 8. worktree_create_with_integration — first parent conflict stops second merge
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 9. ENG-214: worktree_create_with_integration branches the integration
#    worktree from SENSIBLE_RALPH_DEFAULT_BASE_BRANCH (configurable via .sensible-ralph.json),
#    not the literal "main". Confirms a project whose trunk is "dev" can
#    integrate parents on top of dev.
# ---------------------------------------------------------------------------
@test "worktree_create_with_integration uses SENSIBLE_RALPH_DEFAULT_BASE_BRANCH as the integration base" {
  # Create a `dev` branch that diverges from main with a unique file.
  git -C "$REPO_DIR" checkout -b dev -q
  echo "dev-only" > "$REPO_DIR/dev_marker.txt"
  git -C "$REPO_DIR" add dev_marker.txt
  git -C "$REPO_DIR" commit -m "dev marker" -q
  git -C "$REPO_DIR" checkout main -q

  # A parent branch off main with its own unique file — the integration must
  # carry both `dev`'s commits AND the parent's commits, proving the merge
  # was performed onto `dev` rather than `main`.
  git -C "$REPO_DIR" checkout -b "eng-214-parent" -q
  echo "parent" > "$REPO_DIR/parent_file.txt"
  git -C "$REPO_DIR" add parent_file.txt
  git -C "$REPO_DIR" commit -m "parent" -q
  git -C "$REPO_DIR" checkout main -q

  local wt_path="$REPO_DIR/.worktrees/integration-on-dev"

  run bash -c "cd '$REPO_DIR' && export SENSIBLE_RALPH_DEFAULT_BASE_BRANCH=dev && source '$WORKTREE_SH' && worktree_create_with_integration '$wt_path' 'integration-on-dev' 'eng-214-parent'"

  [ "$status" -eq 0 ]
  [ -d "$wt_path" ]
  # `dev`'s marker — present only because the worktree was branched from dev,
  # not main.
  [ -f "$wt_path/dev_marker.txt" ]
  # Parent's content — present because the merge ran.
  [ -f "$wt_path/parent_file.txt" ]
}

@test "worktree_create_with_integration multi-parent conflict leaves conflicts in worktree, writes pending-merges marker" {
  # Parent A: conflicts with main on conflict.txt
  git -C "$REPO_DIR" checkout -b "eng-30-conflict-a"
  echo "parent A version" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "parent A adds conflict.txt"
  git -C "$REPO_DIR" checkout main

  # main also adds conflict.txt — guarantees an add/add conflict with parent A
  echo "main version" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "main adds conflict.txt"

  # Parent B has unique content; the marker must list both A and B (full
  # original list) so the session can drain B after resolving A.
  git -C "$REPO_DIR" checkout -b "eng-31-parent-b"
  echo "content from parent B" > "$REPO_DIR/file-b-unique.txt"
  git -C "$REPO_DIR" add file-b-unique.txt
  git -C "$REPO_DIR" commit -m "parent B adds file-b-unique.txt"
  git -C "$REPO_DIR" checkout main

  local sha_a; sha_a="$(git -C "$REPO_DIR" rev-parse "eng-30-conflict-a")"
  local sha_b; sha_b="$(git -C "$REPO_DIR" rev-parse "eng-31-parent-b")"

  local wt_path="$REPO_DIR/.worktrees/two-parent-conflict"

  run call_fn worktree_create_with_integration "$wt_path" "two-parent-conflict" "eng-30-conflict-a" "eng-31-parent-b"

  [ "$status" -eq 0 ]
  [ -f "$wt_path/.sensible-ralph-pending-merges" ]
  # Marker has 2 lines, each starting with a 40-char hex SHA, in original order.
  local marker_lines; marker_lines="$(wc -l < "$wt_path/.sensible-ralph-pending-merges" | tr -d ' ')"
  [ "$marker_lines" -eq 2 ]
  local line1; line1="$(sed -n '1p' "$wt_path/.sensible-ralph-pending-merges")"
  local line2; line2="$(sed -n '2p' "$wt_path/.sensible-ralph-pending-merges")"
  [[ "$line1" =~ ^[0-9a-f]{40}( .*)?$ ]]
  [[ "$line2" =~ ^[0-9a-f]{40}( .*)?$ ]]
  local sha1; sha1="$(awk '{print $1}' <<< "$line1")"
  local sha2; sha2="$(awk '{print $1}' <<< "$line2")"
  [ "$sha1" = "$sha_a" ]
  [ "$sha2" = "$sha_b" ]
  # Conflict markers in tree
  run git -C "$wt_path" diff --name-only --diff-filter=U
  [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# 10. worktree_branch_state_for_issue — detects per-issue (branch, path) state
#     for the lazy-create / reuse path used by /sr-spec step 7 and the
#     orchestrator's reuse path. ENG-279.
# ---------------------------------------------------------------------------
@test "worktree_branch_state_for_issue: neither branch nor path exists" {
  run call_fn worktree_branch_state_for_issue "eng-279-fresh" "$REPO_DIR/.worktrees/eng-279-fresh"

  [ "$status" -eq 0 ]
  [ "$output" = "neither" ]
}

@test "worktree_branch_state_for_issue: both_exist when branch+worktree match" {
  local wt_path="$REPO_DIR/.worktrees/eng-279-both"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-279-both" -q

  run call_fn worktree_branch_state_for_issue "eng-279-both" "$wt_path"

  [ "$status" -eq 0 ]
  [ "$output" = "both_exist" ]
}

@test "worktree_branch_state_for_issue: partial branch-only when branch exists but path absent" {
  git -C "$REPO_DIR" branch "eng-279-branch-only"

  run call_fn worktree_branch_state_for_issue "eng-279-branch-only" "$REPO_DIR/.worktrees/eng-279-branch-only"

  [ "$status" -eq 0 ]
  [[ "$output" == "partial"$'\t'"branch-only" ]]
}

@test "worktree_branch_state_for_issue: partial path-only when path is a stray dir, branch absent" {
  mkdir -p "$REPO_DIR/.worktrees/eng-279-path-only"
  echo "stray" > "$REPO_DIR/.worktrees/eng-279-path-only/marker.txt"

  run call_fn worktree_branch_state_for_issue "eng-279-path-only" "$REPO_DIR/.worktrees/eng-279-path-only"

  [ "$status" -eq 0 ]
  [[ "$output" == "partial"$'\t'"path-only" ]]
}

@test "worktree_branch_state_for_issue: partial path-only when path is a registered worktree but branch absent" {
  # A registered worktree on some other branch (so the target branch name
  # really is absent) — the helper must still report path-only.
  local wt_path="$REPO_DIR/.worktrees/eng-279-path-only-reg"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "unrelated-branch" -q

  run call_fn worktree_branch_state_for_issue "eng-279-path-only-reg-target" "$wt_path"

  [ "$status" -eq 0 ]
  [[ "$output" == "partial"$'\t'"path-only" ]]
}

@test "worktree_branch_state_for_issue: partial wrong-branch when path is a worktree on a different branch but target branch also exists" {
  # Path is a registered worktree on branch X; target branch Y exists but is
  # checked out somewhere else (or unchecked-out). Reports wrong-branch.
  local wt_path="$REPO_DIR/.worktrees/eng-279-wrong"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-279-wrong-other" -q
  git -C "$REPO_DIR" branch "eng-279-wrong"

  run call_fn worktree_branch_state_for_issue "eng-279-wrong" "$wt_path"

  [ "$status" -eq 0 ]
  [[ "$output" == "partial"$'\t'"wrong-branch" ]]
}

@test "worktree_branch_state_for_issue: partial path-not-worktree when path is a stray dir but branch also exists" {
  # Path exists as a non-registered directory; target branch also exists.
  # Reports path-not-worktree (distinct from wrong-branch — registration matters).
  mkdir -p "$REPO_DIR/.worktrees/eng-279-stray"
  git -C "$REPO_DIR" branch "eng-279-stray"

  run call_fn worktree_branch_state_for_issue "eng-279-stray" "$REPO_DIR/.worktrees/eng-279-stray"

  [ "$status" -eq 0 ]
  [[ "$output" == "partial"$'\t'"path-not-worktree" ]]
}

@test "worktree_branch_state_for_issue: detached-HEAD worktree at path with target branch present is wrong-branch" {
  # A detached-HEAD worktree at $path has no `branch` line in porcelain
  # output. Combined with target branch existing elsewhere, the helper
  # falls through to wrong-branch (the path is a registered worktree but
  # is not checked out to the target branch).
  local wt_path="$REPO_DIR/.worktrees/eng-279-detached"
  local sha; sha="$(git -C "$REPO_DIR" rev-parse HEAD)"
  git -C "$REPO_DIR" worktree add --detach "$wt_path" "$sha" -q
  git -C "$REPO_DIR" branch "eng-279-detached"

  run call_fn worktree_branch_state_for_issue "eng-279-detached" "$wt_path"

  [ "$status" -eq 0 ]
  [[ "$output" == "partial"$'\t'"wrong-branch" ]]
}

# ---------------------------------------------------------------------------
# 11. worktree_merge_parents — sequential parent merges into an existing
#     worktree. ENG-279 reuse path: an issue's branch+worktree already
#     exist (created at /sr-spec step 7); the orchestrator merges any
#     in-review parents in before dispatch.
# ---------------------------------------------------------------------------
@test "worktree_merge_parents: zero parents is a no-op success" {
  local wt_path="$REPO_DIR/.worktrees/eng-279-mp-zero"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-279-mp-zero" -q
  local before; before="$(git -C "$wt_path" rev-parse HEAD)"

  run call_fn worktree_merge_parents "$wt_path"

  [ "$status" -eq 0 ]
  local after; after="$(git -C "$wt_path" rev-parse HEAD)"
  [ "$before" = "$after" ]
}

@test "worktree_merge_parents: single clean parent merges in" {
  git -C "$REPO_DIR" checkout -b "eng-279-mp-parent" -q
  echo "parent" > "$REPO_DIR/parent.txt"
  git -C "$REPO_DIR" add parent.txt
  git -C "$REPO_DIR" commit -m "parent" -q
  git -C "$REPO_DIR" checkout main -q

  local wt_path="$REPO_DIR/.worktrees/eng-279-mp-single"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-279-mp-single" -q

  run call_fn worktree_merge_parents "$wt_path" "eng-279-mp-parent"

  [ "$status" -eq 0 ]
  [ -f "$wt_path/parent.txt" ]
}

@test "worktree_merge_parents: single-parent conflict left in-place, returns 0" {
  # Set up a conflict between the worktree's branch and the parent.
  git -C "$REPO_DIR" checkout -b "eng-279-mp-conflict-parent" -q
  echo "parent version" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "parent conflict" -q
  git -C "$REPO_DIR" checkout main -q

  local wt_path="$REPO_DIR/.worktrees/eng-279-mp-conflict-wt"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-279-mp-conflict-wt" -q
  echo "wt version" > "$wt_path/conflict.txt"
  git -C "$wt_path" add conflict.txt
  git -C "$wt_path" commit -m "wt conflict" -q

  run call_fn worktree_merge_parents "$wt_path" "eng-279-mp-conflict-parent"

  [ "$status" -eq 0 ]
  run git -C "$wt_path" status --porcelain
  [[ "$output" =~ ^(UU|AA) ]]
}

@test "worktree_merge_parents: multi-parent clean merge brings both parents in" {
  git -C "$REPO_DIR" checkout -b "eng-279-mp-a" -q
  echo "A" > "$REPO_DIR/a.txt"
  git -C "$REPO_DIR" add a.txt
  git -C "$REPO_DIR" commit -m "A" -q
  git -C "$REPO_DIR" checkout main -q

  git -C "$REPO_DIR" checkout -b "eng-279-mp-b" -q
  echo "B" > "$REPO_DIR/b.txt"
  git -C "$REPO_DIR" add b.txt
  git -C "$REPO_DIR" commit -m "B" -q
  git -C "$REPO_DIR" checkout main -q

  local wt_path="$REPO_DIR/.worktrees/eng-279-mp-multi"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-279-mp-multi" -q

  run call_fn worktree_merge_parents "$wt_path" "eng-279-mp-a" "eng-279-mp-b"

  [ "$status" -eq 0 ]
  [ -f "$wt_path/a.txt" ]
  [ -f "$wt_path/b.txt" ]
}

@test "worktree_merge_parents multi-parent conflict leaves conflicts in worktree, writes pending-merges marker" {
  # Parent A conflicts with the worktree.
  git -C "$REPO_DIR" checkout -b "eng-279-mp-cflict-a" -q
  echo "parent A" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "A" -q
  git -C "$REPO_DIR" checkout main -q

  git -C "$REPO_DIR" checkout -b "eng-279-mp-cflict-b" -q
  echo "B-only" > "$REPO_DIR/b-only.txt"
  git -C "$REPO_DIR" add b-only.txt
  git -C "$REPO_DIR" commit -m "B" -q
  git -C "$REPO_DIR" checkout main -q

  local sha_a; sha_a="$(git -C "$REPO_DIR" rev-parse "eng-279-mp-cflict-a")"
  local sha_b; sha_b="$(git -C "$REPO_DIR" rev-parse "eng-279-mp-cflict-b")"

  local wt_path="$REPO_DIR/.worktrees/eng-279-mp-cflict-wt"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-279-mp-cflict-wt" -q
  echo "wt version" > "$wt_path/conflict.txt"
  git -C "$wt_path" add conflict.txt
  git -C "$wt_path" commit -m "wt conflict" -q

  run call_fn worktree_merge_parents "$wt_path" "eng-279-mp-cflict-a" "eng-279-mp-cflict-b"

  [ "$status" -eq 0 ]
  [ -f "$wt_path/.sensible-ralph-pending-merges" ]
  local marker_lines; marker_lines="$(wc -l < "$wt_path/.sensible-ralph-pending-merges" | tr -d ' ')"
  [ "$marker_lines" -eq 2 ]
  local sha1; sha1="$(awk 'NR==1 {print $1}' "$wt_path/.sensible-ralph-pending-merges")"
  local sha2; sha2="$(awk 'NR==2 {print $1}' "$wt_path/.sensible-ralph-pending-merges")"
  [ "$sha1" = "$sha_a" ]
  [ "$sha2" = "$sha_b" ]
  run git -C "$wt_path" diff --name-only --diff-filter=U
  [ -n "$output" ]
}

@test "worktree_merge_parents: parent already an ancestor is a no-op" {
  # Parent merged earlier — re-running with the same parent must be a no-op
  # (no merge commit, exit 0).
  git -C "$REPO_DIR" checkout -b "eng-279-mp-anc-parent" -q
  echo "anc" > "$REPO_DIR/anc.txt"
  git -C "$REPO_DIR" add anc.txt
  git -C "$REPO_DIR" commit -m "anc" -q
  git -C "$REPO_DIR" checkout main -q

  local wt_path="$REPO_DIR/.worktrees/eng-279-mp-anc-wt"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-279-mp-anc-wt" -q
  call_fn worktree_merge_parents "$wt_path" "eng-279-mp-anc-parent"
  local after_first; after_first="$(git -C "$wt_path" rev-parse HEAD)"

  run call_fn worktree_merge_parents "$wt_path" "eng-279-mp-anc-parent"

  [ "$status" -eq 0 ]
  local after_second; after_second="$(git -C "$wt_path" rev-parse HEAD)"
  [ "$after_first" = "$after_second" ]
}

@test "worktree_merge_parents: parent ref not found returns non-zero" {
  local wt_path="$REPO_DIR/.worktrees/eng-279-mp-bad"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-279-mp-bad" -q

  run call_fn worktree_merge_parents "$wt_path" "nonexistent-branch"

  [ "$status" -ne 0 ]
  [[ "$output" =~ "parent ref not found" ]]
}

@test "worktree_merge_parents: parent present only as remote tracking ref is accepted" {
  # Synthesize origin/<parent> without a local head.
  git -C "$REPO_DIR" checkout -b "eng-279-mp-remote-parent" -q
  echo "remote" > "$REPO_DIR/remote.txt"
  git -C "$REPO_DIR" add remote.txt
  git -C "$REPO_DIR" commit -m "remote" -q
  local sha; sha="$(git -C "$REPO_DIR" rev-parse HEAD)"
  git -C "$REPO_DIR" checkout main -q
  git -C "$REPO_DIR" branch -D "eng-279-mp-remote-parent" -q
  git -C "$REPO_DIR" update-ref "refs/remotes/origin/eng-279-mp-remote-parent" "$sha"

  local wt_path="$REPO_DIR/.worktrees/eng-279-mp-remote-wt"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-279-mp-remote-wt" -q

  run call_fn worktree_merge_parents "$wt_path" "eng-279-mp-remote-parent"

  [ "$status" -eq 0 ]
  [ -f "$wt_path/remote.txt" ]
}

# ---------------------------------------------------------------------------
# 12. ENG-282: pending-merges marker contract for both helpers.
# ---------------------------------------------------------------------------

@test "worktree_create_with_integration: marker not written on clean multi-parent merge" {
  git -C "$REPO_DIR" checkout -b "eng-282-clean-a" -q
  echo "A" > "$REPO_DIR/a.txt"
  git -C "$REPO_DIR" add a.txt
  git -C "$REPO_DIR" commit -m "A" -q
  git -C "$REPO_DIR" checkout main -q

  git -C "$REPO_DIR" checkout -b "eng-282-clean-b" -q
  echo "B" > "$REPO_DIR/b.txt"
  git -C "$REPO_DIR" add b.txt
  git -C "$REPO_DIR" commit -m "B" -q
  git -C "$REPO_DIR" checkout main -q

  local wt_path="$REPO_DIR/.worktrees/eng-282-clean-create"

  run call_fn worktree_create_with_integration "$wt_path" "eng-282-clean-create" "eng-282-clean-a" "eng-282-clean-b"

  [ "$status" -eq 0 ]
  [ -f "$wt_path/a.txt" ]
  [ -f "$wt_path/b.txt" ]
  [ ! -f "$wt_path/.sensible-ralph-pending-merges" ]
}

@test "worktree_merge_parents: marker not written on clean multi-parent merge" {
  git -C "$REPO_DIR" checkout -b "eng-282-mp-clean-a" -q
  echo "A" > "$REPO_DIR/a.txt"
  git -C "$REPO_DIR" add a.txt
  git -C "$REPO_DIR" commit -m "A" -q
  git -C "$REPO_DIR" checkout main -q

  git -C "$REPO_DIR" checkout -b "eng-282-mp-clean-b" -q
  echo "B" > "$REPO_DIR/b.txt"
  git -C "$REPO_DIR" add b.txt
  git -C "$REPO_DIR" commit -m "B" -q
  git -C "$REPO_DIR" checkout main -q

  local wt_path="$REPO_DIR/.worktrees/eng-282-mp-clean-wt"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-282-mp-clean-wt" -q

  run call_fn worktree_merge_parents "$wt_path" "eng-282-mp-clean-a" "eng-282-mp-clean-b"

  [ "$status" -eq 0 ]
  [ -f "$wt_path/a.txt" ]
  [ -f "$wt_path/b.txt" ]
  [ ! -f "$wt_path/.sensible-ralph-pending-merges" ]
}

@test "worktree_merge_parents: idempotent re-run after manual conflict resolution" {
  # Two parents: A conflicts with the worktree's HEAD, B is clean. After
  # the first call writes the marker and leaves A's conflict in tree, the
  # session resolves A and re-invokes the helper passing the marker SHAs.
  # The ancestor-skip + SHA-arg branches both fire on the re-run.
  git -C "$REPO_DIR" checkout -b "eng-282-idem-a" -q
  echo "parent A" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "A" -q
  git -C "$REPO_DIR" checkout main -q

  git -C "$REPO_DIR" checkout -b "eng-282-idem-b" -q
  echo "B" > "$REPO_DIR/b.txt"
  git -C "$REPO_DIR" add b.txt
  git -C "$REPO_DIR" commit -m "B" -q
  git -C "$REPO_DIR" checkout main -q

  local wt_path="$REPO_DIR/.worktrees/eng-282-idem-wt"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-282-idem-wt" -q
  echo "wt version" > "$wt_path/conflict.txt"
  git -C "$wt_path" add conflict.txt
  git -C "$wt_path" commit -m "wt conflict" -q

  run call_fn worktree_merge_parents "$wt_path" "eng-282-idem-a" "eng-282-idem-b"
  [ "$status" -eq 0 ]
  [ -f "$wt_path/.sensible-ralph-pending-merges" ]

  # Resolve A's conflict: keep "wt version", commit to finish the merge.
  echo "resolved" > "$wt_path/conflict.txt"
  git -C "$wt_path" add conflict.txt
  git -C "$wt_path" commit --no-edit -q

  # Re-invoke with marker SHAs (as the session would).
  local shas; shas="$(awk '{print $1}' "$wt_path/.sensible-ralph-pending-merges" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  run call_fn worktree_merge_parents "$wt_path" $shas

  [ "$status" -eq 0 ]
  [ ! -f "$wt_path/.sensible-ralph-pending-merges" ]
  [ -f "$wt_path/b.txt" ]
}

@test "worktree_merge_parents: marker preserved when re-run hits another conflict" {
  # Three parents: A clean, B conflicts, C also conflicts (touches the same
  # file as B with incompatible content). First run merges A, conflicts on
  # B, writes a 3-SHA marker. Resolve B + commit, re-run, C conflicts —
  # marker still present with the same 3 SHAs.
  git -C "$REPO_DIR" checkout -b "eng-282-pres-a" -q
  echo "A" > "$REPO_DIR/a.txt"
  git -C "$REPO_DIR" add a.txt
  git -C "$REPO_DIR" commit -m "A" -q
  git -C "$REPO_DIR" checkout main -q

  git -C "$REPO_DIR" checkout -b "eng-282-pres-b" -q
  echo "B version" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "B" -q
  git -C "$REPO_DIR" checkout main -q

  git -C "$REPO_DIR" checkout -b "eng-282-pres-c" -q
  echo "C version" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "C" -q
  git -C "$REPO_DIR" checkout main -q

  local sha_a; sha_a="$(git -C "$REPO_DIR" rev-parse "eng-282-pres-a")"
  local sha_b; sha_b="$(git -C "$REPO_DIR" rev-parse "eng-282-pres-b")"
  local sha_c; sha_c="$(git -C "$REPO_DIR" rev-parse "eng-282-pres-c")"

  local wt_path="$REPO_DIR/.worktrees/eng-282-pres-wt"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-282-pres-wt" -q
  echo "wt version" > "$wt_path/conflict.txt"
  git -C "$wt_path" add conflict.txt
  git -C "$wt_path" commit -m "wt conflict" -q

  run call_fn worktree_merge_parents "$wt_path" "eng-282-pres-a" "eng-282-pres-b" "eng-282-pres-c"
  [ "$status" -eq 0 ]
  [ -f "$wt_path/.sensible-ralph-pending-merges" ]
  local marker_lines; marker_lines="$(wc -l < "$wt_path/.sensible-ralph-pending-merges" | tr -d ' ')"
  [ "$marker_lines" -eq 3 ]

  # Resolve B: keep B version, commit.
  echo "B version" > "$wt_path/conflict.txt"
  git -C "$wt_path" add conflict.txt
  git -C "$wt_path" commit --no-edit -q

  # Re-run with marker SHAs. A is now ancestor (skipped), B is now ancestor
  # (skipped via merge after resolution), C conflicts.
  local shas; shas="$(awk '{print $1}' "$wt_path/.sensible-ralph-pending-merges" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  run call_fn worktree_merge_parents "$wt_path" $shas

  [ "$status" -eq 0 ]
  [ -f "$wt_path/.sensible-ralph-pending-merges" ]
  marker_lines="$(wc -l < "$wt_path/.sensible-ralph-pending-merges" | tr -d ' ')"
  [ "$marker_lines" -eq 3 ]
  # Marker still lists all 3 original SHAs in original order
  local s1 s2 s3
  s1="$(awk 'NR==1 {print $1}' "$wt_path/.sensible-ralph-pending-merges")"
  s2="$(awk 'NR==2 {print $1}' "$wt_path/.sensible-ralph-pending-merges")"
  s3="$(awk 'NR==3 {print $1}' "$wt_path/.sensible-ralph-pending-merges")"
  [ "$s1" = "$sha_a" ]
  [ "$s2" = "$sha_b" ]
  [ "$s3" = "$sha_c" ]
}

@test "worktree_merge_parents: zero-parent invocation with no marker is a no-op success" {
  local wt_path="$REPO_DIR/.worktrees/eng-282-zero-no-marker"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-282-zero-no-marker" -q
  local before; before="$(git -C "$wt_path" rev-parse HEAD)"

  run call_fn worktree_merge_parents "$wt_path"

  [ "$status" -eq 0 ]
  [ ! -f "$wt_path/.sensible-ralph-pending-merges" ]
  local after; after="$(git -C "$wt_path" rev-parse HEAD)"
  [ "$before" = "$after" ]
}

@test "worktree_merge_parents: refuses zero-parent invocation when marker exists" {
  local wt_path="$REPO_DIR/.worktrees/eng-282-zero-with-marker"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-282-zero-with-marker" -q

  # Write a fake marker file with arbitrary content.
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa some-display\n' > "$wt_path/.sensible-ralph-pending-merges"
  local before_content; before_content="$(cat "$wt_path/.sensible-ralph-pending-merges")"

  run call_fn worktree_merge_parents "$wt_path"

  [ "$status" -eq 1 ]
  [[ "$output" =~ "refusing zero-parent invocation while marker exists" ]]
  # Marker file is unchanged
  local after_content; after_content="$(cat "$wt_path/.sensible-ralph-pending-merges")"
  [ "$before_content" = "$after_content" ]
}

@test "worktree_merge_parents: SHA-pinned retry merges the original commit even after the named ref advances" {
  # A0 conflicts with the worktree; B is clean.
  git -C "$REPO_DIR" checkout -b "eng-282-pin-a" -q
  echo "A0 version" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "A0" -q
  local sha_a0; sha_a0="$(git -C "$REPO_DIR" rev-parse "eng-282-pin-a")"
  git -C "$REPO_DIR" checkout main -q

  git -C "$REPO_DIR" checkout -b "eng-282-pin-b" -q
  echo "B-only" > "$REPO_DIR/b.txt"
  git -C "$REPO_DIR" add b.txt
  git -C "$REPO_DIR" commit -m "B" -q
  git -C "$REPO_DIR" checkout main -q

  local wt_path="$REPO_DIR/.worktrees/eng-282-pin-wt"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-282-pin-wt" -q
  echo "wt version" > "$wt_path/conflict.txt"
  git -C "$wt_path" add conflict.txt
  git -C "$wt_path" commit -m "wt conflict" -q

  run call_fn worktree_merge_parents "$wt_path" "eng-282-pin-a" "eng-282-pin-b"
  [ "$status" -eq 0 ]
  [ -f "$wt_path/.sensible-ralph-pending-merges" ]

  # Advance the local A ref to A1 with new content. The marker still pins A0.
  git -C "$REPO_DIR" checkout "eng-282-pin-a" -q
  echo "A1 different content" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit --amend --no-edit -q
  local sha_a1; sha_a1="$(git -C "$REPO_DIR" rev-parse "eng-282-pin-a")"
  [ "$sha_a0" != "$sha_a1" ]
  git -C "$REPO_DIR" checkout main -q

  # Resolve A0's conflict by taking A0's content (proving the merge was
  # against A0, not A1).
  echo "A0 version" > "$wt_path/conflict.txt"
  git -C "$wt_path" add conflict.txt
  git -C "$wt_path" commit --no-edit -q

  # Re-invoke with the marker SHAs (A0_SHA + B_SHA).
  local shas; shas="$(awk '{print $1}' "$wt_path/.sensible-ralph-pending-merges" | tr '\n' ' ')"
  # shellcheck disable=SC2086
  run call_fn worktree_merge_parents "$wt_path" $shas

  [ "$status" -eq 0 ]
  [ ! -f "$wt_path/.sensible-ralph-pending-merges" ]
  # File content is A0's, NOT A1's. (Confirms the merge was not influenced
  # by the advanced ref.)
  [ "$(cat "$wt_path/conflict.txt")" = "A0 version" ]
}

@test "worktree_merge_parents: helper accepts a 40-char hex SHA as a parent arg" {
  git -C "$REPO_DIR" checkout -b "eng-282-sha-arg" -q
  echo "sha-arg-content" > "$REPO_DIR/sha-arg.txt"
  git -C "$REPO_DIR" add sha-arg.txt
  git -C "$REPO_DIR" commit -m "sha arg" -q
  local sha; sha="$(git -C "$REPO_DIR" rev-parse "eng-282-sha-arg")"
  git -C "$REPO_DIR" checkout main -q

  local wt_path="$REPO_DIR/.worktrees/eng-282-mp-sha-arg-wt"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-282-mp-sha-arg-wt" -q

  run call_fn worktree_merge_parents "$wt_path" "$sha"

  [ "$status" -eq 0 ]
  [ -f "$wt_path/sha-arg.txt" ]
  [ ! -f "$wt_path/.sensible-ralph-pending-merges" ]
}

@test "worktree_create_with_integration: helper accepts a 40-char hex SHA as a parent arg" {
  git -C "$REPO_DIR" checkout -b "eng-282-create-sha-arg" -q
  echo "create-sha-arg-content" > "$REPO_DIR/create-sha-arg.txt"
  git -C "$REPO_DIR" add create-sha-arg.txt
  git -C "$REPO_DIR" commit -m "create sha arg" -q
  local sha; sha="$(git -C "$REPO_DIR" rev-parse "eng-282-create-sha-arg")"
  git -C "$REPO_DIR" checkout main -q

  local wt_path="$REPO_DIR/.worktrees/eng-282-create-sha-arg-wt"

  run call_fn worktree_create_with_integration "$wt_path" "eng-282-create-sha-arg-wt" "$sha"

  [ "$status" -eq 0 ]
  [ -f "$wt_path/create-sha-arg.txt" ]
  [ ! -f "$wt_path/.sensible-ralph-pending-merges" ]
}

@test "worktree_create_with_integration: SHA-pinned input merges the pinned commit even after the named ref advances" {
  # First-run-only equivalent of test 10b: cannot literally re-invoke the
  # create helper post-conflict (git worktree add fails on existing path),
  # so we instead pre-advance the named ref before the call and pass the
  # original SHA as input. This exercises the SHA-arg branch in the create
  # helper's resolution loop and proves that input SHA → merge target.
  git -C "$REPO_DIR" checkout -b "eng-282-create-pin-a" -q
  echo "A0 content" > "$REPO_DIR/pinned.txt"
  git -C "$REPO_DIR" add pinned.txt
  git -C "$REPO_DIR" commit -m "A0" -q
  local sha_a0; sha_a0="$(git -C "$REPO_DIR" rev-parse "eng-282-create-pin-a")"

  # Advance the ref to a different commit BEFORE the helper runs.
  echo "A1 content" > "$REPO_DIR/pinned.txt"
  git -C "$REPO_DIR" add pinned.txt
  git -C "$REPO_DIR" commit --amend --no-edit -q
  local sha_a1; sha_a1="$(git -C "$REPO_DIR" rev-parse "eng-282-create-pin-a")"
  [ "$sha_a0" != "$sha_a1" ]
  git -C "$REPO_DIR" checkout main -q

  local wt_path="$REPO_DIR/.worktrees/eng-282-create-pin-wt"

  # Pass A0's original SHA. The named ref now points at A1, but the helper
  # must merge the SHA we asked for.
  run call_fn worktree_create_with_integration "$wt_path" "eng-282-create-pin-wt" "$sha_a0"

  [ "$status" -eq 0 ]
  [ -f "$wt_path/pinned.txt" ]
  [ "$(cat "$wt_path/pinned.txt")" = "A0 content" ]
}

@test "worktree_create_with_integration: ancestor-skip kicks in when a parent is already in trunk" {
  # Pre-merge parent A into the trunk so A is an ancestor of HEAD when the
  # helper runs. The helper must skip A (no-op) and merge B normally. Tests
  # the ancestor-skip branch in worktree_create_with_integration's loop —
  # required so the helper is re-invokable post-conflict via the session's
  # drain flow (which actually goes through worktree_merge_parents, but the
  # spec keeps the loop bodies symmetric to prevent drift).
  git -C "$REPO_DIR" checkout -b "eng-282-anc-a" -q
  echo "A content" > "$REPO_DIR/a.txt"
  git -C "$REPO_DIR" add a.txt
  git -C "$REPO_DIR" commit -m "A" -q
  git -C "$REPO_DIR" checkout main -q
  git -C "$REPO_DIR" merge "eng-282-anc-a" --no-edit -q

  git -C "$REPO_DIR" checkout -b "eng-282-anc-b" main^ -q
  echo "B content" > "$REPO_DIR/b.txt"
  git -C "$REPO_DIR" add b.txt
  git -C "$REPO_DIR" commit -m "B" -q
  git -C "$REPO_DIR" checkout main -q

  local wt_path="$REPO_DIR/.worktrees/eng-282-anc-create-wt"

  run call_fn worktree_create_with_integration "$wt_path" "eng-282-anc-create-wt" "eng-282-anc-a" "eng-282-anc-b"

  [ "$status" -eq 0 ]
  [ -f "$wt_path/a.txt" ]
  [ -f "$wt_path/b.txt" ]
  [ ! -f "$wt_path/.sensible-ralph-pending-merges" ]
}

@test "worktree_merge_parents: single-parent conflict writes pending-merges marker with one SHA line" {
  git -C "$REPO_DIR" checkout -b "eng-282-sp-merge-parent" -q
  echo "parent version" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "parent" -q
  local parent_sha; parent_sha="$(git -C "$REPO_DIR" rev-parse "eng-282-sp-merge-parent")"
  git -C "$REPO_DIR" checkout main -q

  local wt_path="$REPO_DIR/.worktrees/eng-282-sp-merge-wt"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-282-sp-merge-wt" -q
  echo "wt version" > "$wt_path/conflict.txt"
  git -C "$wt_path" add conflict.txt
  git -C "$wt_path" commit -m "wt conflict" -q

  run call_fn worktree_merge_parents "$wt_path" "eng-282-sp-merge-parent"

  [ "$status" -eq 0 ]
  run git -C "$wt_path" status --porcelain
  [[ "$output" =~ ^(UU|AA) ]]
  [ -f "$wt_path/.sensible-ralph-pending-merges" ]
  local marker_lines; marker_lines="$(wc -l < "$wt_path/.sensible-ralph-pending-merges" | tr -d ' ')"
  [ "$marker_lines" -eq 1 ]
  local line; line="$(cat "$wt_path/.sensible-ralph-pending-merges")"
  [[ "$line" =~ ^[0-9a-f]{40}( .*)?$ ]]
  local sha; sha="$(awk '{print $1}' <<< "$line")"
  [ "$sha" = "$parent_sha" ]
}

@test "worktree_merge_parents: fails closed when marker path is occupied by a non-file" {
  # Codex review of ENG-282 flagged: marker write was unchecked, so any I/O
  # failure (disk full, perms, hostile FS state) silently returned 0 and left
  # the worktree in MERGING state without an authoritative marker —
  # unrecoverable on the next session because the new contract treats
  # MERGE_HEAD without a valid marker as unowned state.
  #
  # Trigger I/O failure by pre-creating the marker path as a directory. The
  # write helper must (a) detect that the target is not a regular file and
  # refuse, and (b) propagate the failure up through the caller as non-zero.
  # This pins write-result checking AND defends against marker-path corruption.
  git -C "$REPO_DIR" checkout -b "eng-282-failclose-a" -q
  echo "parent A" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "A" -q
  git -C "$REPO_DIR" checkout main -q

  local wt_path="$REPO_DIR/.worktrees/eng-282-failclose-wt"
  git -C "$REPO_DIR" worktree add "$wt_path" -b "eng-282-failclose-wt" -q
  echo "wt version" > "$wt_path/conflict.txt"
  git -C "$wt_path" add conflict.txt
  git -C "$wt_path" commit -m "wt conflict" -q

  # Hostile preexisting state at the marker path.
  mkdir "$wt_path/.sensible-ralph-pending-merges"

  run call_fn worktree_merge_parents "$wt_path" "eng-282-failclose-a"

  [ "$status" -ne 0 ]
  # The pre-existing directory is untouched (no half-state), and no stray
  # tempfile was left in the worktree from an atomic-rename attempt.
  [ -d "$wt_path/.sensible-ralph-pending-merges" ]
  local leftovers
  leftovers="$(find "$wt_path" -maxdepth 1 -name '.sensible-ralph-pending-merges.*' 2>/dev/null)"
  [ -z "$leftovers" ]
  # Stderr surfaces the failure so operators can diagnose without grepping.
  [[ "$output" =~ "marker" ]]
}

@test "worktree_create_with_integration: fails closed when marker path is occupied by a non-file" {
  # Symmetric coverage of the create-helper's marker-write contract. Mirrors
  # the merge_parents test above but exercises the create path's integration
  # loop. The worktree path must not exist before `git worktree add`, so we
  # arrange the hostile marker directory to appear after the merge: by giving
  # parent A a tracked subdirectory at the marker path. Git materializes that
  # directory during the merge of A, then the marker write attempt finds it
  # already occupied and must fail closed.
  git -C "$REPO_DIR" checkout -b "eng-282-create-failclose-a" -q
  mkdir "$REPO_DIR/.sensible-ralph-pending-merges"
  echo "decoy" > "$REPO_DIR/.sensible-ralph-pending-merges/decoy.txt"
  git -C "$REPO_DIR" add .sensible-ralph-pending-merges/decoy.txt
  git -C "$REPO_DIR" commit -m "A introduces hostile marker dir" -q
  git -C "$REPO_DIR" checkout main -q
  rm -rf "$REPO_DIR/.sensible-ralph-pending-merges"

  # Parent B: conflicts with main on conflict.txt so the integration loop
  # stops on B and tries to write the marker after A has populated the dir.
  git -C "$REPO_DIR" checkout -b "eng-282-create-failclose-b" -q
  echo "B version" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "B" -q
  git -C "$REPO_DIR" checkout main -q

  echo "main version" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "main conflict" -q

  local wt_path="$REPO_DIR/.worktrees/eng-282-create-failclose-wt"

  run call_fn worktree_create_with_integration "$wt_path" "eng-282-create-failclose-wt" \
    "eng-282-create-failclose-a" "eng-282-create-failclose-b"

  [ "$status" -ne 0 ]
  # Hostile dir untouched, no stray temp file.
  [ -d "$wt_path/.sensible-ralph-pending-merges" ]
  local leftovers
  leftovers="$(find "$wt_path" -maxdepth 1 -name '.sensible-ralph-pending-merges.*' 2>/dev/null)"
  [ -z "$leftovers" ]
  [[ "$output" =~ "marker" ]]
}

@test "worktree_create_with_integration: single-parent conflict writes pending-merges marker with one SHA line" {
  # Single-parent conflict via create path — orchestrator doesn't route
  # single-parent through the create helper today, but the helper contract
  # is unified and should match worktree_merge_parents.
  git -C "$REPO_DIR" checkout -b "eng-282-sp-create-parent" -q
  echo "parent version" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "parent" -q
  local parent_sha; parent_sha="$(git -C "$REPO_DIR" rev-parse "eng-282-sp-create-parent")"
  git -C "$REPO_DIR" checkout main -q

  echo "main version" > "$REPO_DIR/conflict.txt"
  git -C "$REPO_DIR" add conflict.txt
  git -C "$REPO_DIR" commit -m "main conflict" -q

  local wt_path="$REPO_DIR/.worktrees/eng-282-sp-create-wt"

  run call_fn worktree_create_with_integration "$wt_path" "eng-282-sp-create-wt" "eng-282-sp-create-parent"

  [ "$status" -eq 0 ]
  run git -C "$wt_path" status --porcelain
  [[ "$output" =~ ^(UU|AA) ]]
  [ -f "$wt_path/.sensible-ralph-pending-merges" ]
  local marker_lines; marker_lines="$(wc -l < "$wt_path/.sensible-ralph-pending-merges" | tr -d ' ')"
  [ "$marker_lines" -eq 1 ]
  local line; line="$(cat "$wt_path/.sensible-ralph-pending-merges")"
  [[ "$line" =~ ^[0-9a-f]{40}( .*)?$ ]]
  local sha; sha="$(awk '{print $1}' <<< "$line")"
  [ "$sha" = "$parent_sha" ]
}
