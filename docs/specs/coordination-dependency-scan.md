# Coordination-dependency scan in `/sr-spec` and cleanup in `/close-issue`

**Linear:** ENG-280
**Spec base SHA:** `fc6166a762ee42e57a018a065f882c1f2f208c7e`

## Goal

Detect file-level coupling between a new spec and the existing Approved
spec set at `/sr-spec` finalization time, before the issue transitions
to `Approved` and becomes dispatchable. Surface candidate `blocked-by`
edges to the operator with reasoning, write accepted edges with a
machine-parseable audit trail, and clean them up at `/close-issue` so
they don't pollute the relation graph after the issue lands.

The detection is **reasoning-driven**, not regex-based. A script can
flag that two specs reference the same path; only reasoning can judge
whether the edits collide or are colocated to disjoint sections. The
`/sr-spec` dialogue already has Claude's full attention and can do
that judgment in-line.

## Symptoms this resolves

1. **Operator forgets to declare `blocked-by` for a coordination
   dependency.** Two issues that touch the same file, or where one
   renames a file the other modifies, today only get sequenced if the
   operator notices and adds the relation manually at design time.
   When they don't, the orchestrator dispatches in arbitrary order
   and the second one to land hits a merge conflict that smarter
   ordering would have prevented.
2. **No audit trail for "why is this blocked-by here?"** Linear's
   relation graph treats every `blocked-by` edge identically, so a
   reviewer can't distinguish a semantic dependency ("B uses an
   interface A introduces") from a coordination dependency ("B and A
   both edit `lib/scope.sh::_scope_load`"). After the issue lands,
   the coordination edges accrete and clutter the graph.

This issue resolves the first symptom for the `/sr-spec` write path
and the second for both write and close paths. ENG-281 is the
companion issue that adds the equivalent backstop scan to
`/sr-start`'s preflight; it reuses the same marker, label, and
`/close-issue` cleanup.

## Architecture

The scan lives at a new **step 11** in `/sr-spec`, between the codex
review gate (existing step 10, unchanged) and finalize (currently
step 11, renumbered to step 12). Cleanup lives at a new **step 8** in
`/close-issue`, between the `Done` transition (step 7, unchanged) and
the codex-broker reap + worktree teardown (currently step 8,
renumbered to step 9).

The renumbering is intentionally minimal — only the new steps and
the immediately-following existing step bump. All other step numbers
in both skills' SKILL.md stay as they are today.

```
/sr-spec  (current step numbers: 1, 6.5, 7, 10, 11; with informal
           "Spec self-review" and "User review gate" sections
           between 7 and 10 — those informal sections stay informal)
  step 1-10   (unchanged, including step 10 = codex review gate)
  step 11     coord-dep scan (operator-interaction-only; NO Linear writes)  ← NEW
                ├─ skills/sr-spec/scripts/coord_dep_scan.sh   (data assembly)
                ├─ structured-prompt reasoning (skill prose)   (judgment)
                └─ writes <worktree>/.sensible-ralph-coord-dep.json (transport file)
  step 12     finalize (was step 11; absorbs coord-dep writes from step 11):
                ├─ read accepted_edges from transport file
                ├─ capture INITIAL_BLOCKERS
                ├─ push spec description
                ├─ relation-add for ADD_LIST = (PREREQS ∪ accepted_parents) \ INITIAL_BLOCKERS
                │     (per-edge retry/skip/abort on failure; track committed_parents)
                ├─ if accepted_parents non-empty: post audit comment LAST
                │     (lists all accepted_parents, NOT just committed; structured
                │      ```coord-dep-audit block is cleanup authority)
                ├─ if accepted_parents non-empty: linear_add_label (coord-dep)
                ├─ verify ACTUAL == INITIAL_BLOCKERS ∪ PREREQS ∪ accepted_parents
                ├─ transition Approved
                └─ delete transport file on success

/close-issue  (current numbered steps start at 4; pre-step ritual
               sections — Capture issue ID, Main-checkout-CWD
               invariant, Source plugin libs, Resolve FEATURE_BRANCH,
               Pre-flight — are unnumbered and unchanged)
  steps 4-7   (unchanged, including step 7 = transition Linear issue to Done)
  step 8      coord-dep cleanup             ← NEW
                └─ skills/close-issue/scripts/cleanup_coord_dep.sh
                    ├─ walk all comments, regex-extract parent IDs, dedup
                    ├─ for each: linear issue relation delete (best-effort)
                    └─ linear_remove_label (once)
  step 9      reap codex broker + remove worktree (was step 8)
```

`/close-issue`'s cleanup runs **after** the `Done` transition: a
failure in cleanup is housekeeping, not a state-graph violation, so
the high-value mutation lands first. Best-effort cleanup matches how
`/close-issue` already treats post-`Done` work.

The choice to run the scan **after** the codex gate is deliberate.
The scan typically only adds blockers — it does not rewrite the spec.
Running it on already-codex-cleared content avoids re-scanning after
substantive codex iterations and keeps finalize step 12 focused on
Linear-side mutations.

## The audit-comment contract

Each finalize that adds at least one coord-dep edge posts ONE
consolidated audit comment in this exact shape:

````
**Coordination dependencies added by /sr-spec scan**

- blocked-by ENG-X — both restructure `lib/scope.sh`'s `_scope_load` function
- blocked-by ENG-Y — ENG-Y renames `foo.sh` which this spec edits inline

```coord-dep-audit
{"parents": ["ENG-X", "ENG-Y"]}
```

Will be removed automatically on `/close-issue`.
````

Cleanup parses ONLY the ` ```coord-dep-audit ` fenced block; bullet
lines and any other free-form content are NOT delete authority. The
fence language tag is unusual enough that prose can't fake it
accidentally; the JSON object is forward-compatible (new keys can
land later without breaking older parsers).

Each block must be parsed INDEPENDENTLY at cleanup time so a
malformed JSON block (e.g., hand-edited by an operator) doesn't
suppress valid `parents` arrays from other blocks. The full
algorithm lives in Component 5 below; a single-pass `jq -s` over
the concatenated stream is explicitly NOT permitted.

The format is documented as a `## Audit comment format` header in
both `skills/sr-spec/SKILL.md` (step 12) and
`skills/close-issue/SKILL.md` (step 8), with `coord_dep_scan.sh`'s
header comment as the single source of truth. Both `/sr-spec`
today and ENG-281's `/sr-start` scan emit this exact shape;
cleanup is the same regardless of producer.

## Components

### 1. Plugin option, defaults, preflight

Add a new `userConfig` option to `.claude-plugin/plugin.json`:

```json
"coord_dep_label": {
  "type": "string",
  "title": "Coordination-dependency label",
  "description": "Label applied by /sr-spec when its coord-dep scan adds blocked-by edges; cleared by /close-issue (default: ralph-coord-dep)",
  "default": "ralph-coord-dep"
}
```

Mirror the default in `lib/defaults.sh` (the existing comment at the
top of that file says "The defaults mirror the plugin.json userConfig
defaults — update in lockstep"):

```bash
: "${CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL=ralph-coord-dep}"
# ...
export CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL
```

Append `CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL` to the hardcoded
`required_vars` array in
`skills/sr-start/scripts/lib/preflight_labels.sh::preflight_labels_check`:

```bash
local -a required_vars=(
  CLAUDE_PLUGIN_OPTION_FAILED_LABEL
  CLAUDE_PLUGIN_OPTION_STALE_PARENT_LABEL
  CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL
)
```

The hardcoded list (rather than convention-based discovery) is
deliberate per that file's design note: explicit lists keep the set
of "things that must exist in Linear" auditable.

**Upgrade note** for the spec: workspaces upgrading the plugin must
create the `ralph-coord-dep` workspace-scoped label once before the
next `/sr-start` runs, otherwise preflight refuses with a clear
diagnostic naming both the literal label and the env var. Add to
`skills/sr-start/SKILL.md` Prerequisites alongside the existing
`ralph-failed` / `stale-parent` setup commands.

### 2. New `lib/linear.sh` helper: `linear_remove_label`

Mirrors `linear_add_label`'s pattern. Header comment in the same
style as the rest of `lib/linear.sh`:

```
# Remove a label from an issue. Returns 0 on success or no-op-on-absent
# (the label wasn't on the issue to begin with — that's idempotent
# cleanup, not an error). Returns non-zero if the label doesn't exist
# in the workspace, or the API call fails.
#
# Implementation: fetch current labels, build --label flags for the
# reduced set, call `linear issue update`. Corner case — when the
# reduced set is empty (target was the only label on the issue) —
# `linear issue update` with no --label flags has ambiguous semantics
# (preserve-all vs. clear-all depending on CLI version), so for the
# empty-reduced-set case fall back to a Linear GraphQL
# `issueRemoveLabel(id, labelId)` mutation via `linear api`. The
# implementer picks one path consistently and documents which.
```

Implementation choice (CLI vs. GraphQL throughout) is left to the
implementer; either works. The spec describes the contract.

Failure modes worth surfacing in the helper's stderr diagnostics:

- Workspace-level label name doesn't exist → name the literal label
  in the message (matches `linear_label_exists`'s style).
- API failure on the lookup or mutation → name the issue ID and the
  label name.

Callers (`/close-issue`'s cleanup helper) treat non-zero as
log-and-continue.

### 3. `/sr-spec` step 11 — the scan helper

New file: `skills/sr-spec/scripts/coord_dep_scan.sh`. Pure data
assembly, no decisions. Does not write to Linear.

Inputs:

- `$1` — absolute path to the new spec file (`docs/specs/<topic>.md`
  in the current worktree).
- Env: `$ISSUE_ID`, `$SENSIBLE_RALPH_PROJECTS`,
  `$CLAUDE_PLUGIN_OPTION_APPROVED_STATE`,
  `$CLAUDE_PLUGIN_OPTION_FAILED_LABEL`.
- Remaining positional args (`$2`, `$3`, ...) — design-time PREREQS
  passed in from the dialogue, to be merged with Linear's existing
  `blocked-by` set into the exclusion list.

Behavior:

1. Source `lib/linear.sh` and `lib/scope.sh` defensively (the skill
   should already have sourced them, but idempotent re-source is
   harmless).
2. List Approved peers via `linear_list_approved_issues`. Filter out
   `$ISSUE_ID` itself (an issue can already be Approved during a
   re-spec; don't compare to self).
3. For each peer, fetch its description via
   `linear issue view <peer-id> --json | jq -r '.description // empty'`.
   Capture as `peers[<peer-id>] = { title, description }`.
4. Fetch the child's existing `blocked-by` set via
   `linear_get_issue_blockers "$ISSUE_ID"`. Take the union with the
   design-time PREREQS passed as positional args; that union is
   `existing_blockers`.
5. Read the new spec file content into a string.
6. Emit a single JSON object on stdout:

   ```json
   {
     "issue_id": "ENG-280",
     "new_spec": { "path": "docs/specs/<topic>.md", "body": "..." },
     "peers": [
       { "id": "ENG-X", "title": "...", "description": "..." }
     ],
     "existing_blockers": ["ENG-A", "ENG-B"]
   }
   ```

Failure modes (all return non-zero, with stderr diagnostics):

- Linear CLI failure listing peers or viewing any peer → exit 1.
- Empty peer list → emit valid JSON with `peers: []`, exit 0
  (the skill prose fast-paths to "No coordination dependencies detected").
- New spec file does not exist at the passed path → exit 2 with a
  "step 7 spec file missing" message (sanity check; should be
  impossible in normal flow).

The script writes nothing to Linear. All mutations happen in skill
prose after operator confirmation.

### 4. `/sr-spec` step 11 — reasoning, operator gate (skill prose)

Operator-interaction-only. Builds the `accepted_edges` list,
persists it to a transport file at
`<worktree>/.sensible-ralph-coord-dep.json` (so step 12 can pick
it up across the shell-process boundary), and writes nothing to
Linear. All Linear mutations defer to step 12 inside its
all-or-nothing-before-Approved sequence — keeps the In-Design
issue residue-free until finalize succeeds atomically.

1. **Load any existing transport file** into `prior_accepted_edges`
   (empty array if absent). A prior `/sr-spec` may have added
   relations and aborted before posting the audit comment; loading
   (rather than clearing) lets the operator re-audit those at
   sub-step 6 so step 12 can re-post the audit comment.

   ```bash
   COORD_DEP_FILE="$WORKTREE_PATH/.sensible-ralph-coord-dep.json"
   if [[ -f "$COORD_DEP_FILE" ]]; then
     prior_accepted_edges=$(cat "$COORD_DEP_FILE")
   else
     prior_accepted_edges='[]'
   fi
   ```

2. **Label-existence preflight.** `linear issue update --label`
   silently no-ops on unknown labels, so step 12's `linear_add_label`
   would be a silent no-op without this gate, hiding incomplete
   cleanups later. Refuse to proceed if missing; operator can
   create the label and retry, or skip step 11 entirely (proceed
   to step 12 with no coord-dep writes; ENG-281's `/sr-start`
   backstop covers missed edges).

   ```bash
   linear_label_exists "$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL" || {
     echo "step 11: workspace label '$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL' missing — create it or update plugin config" >&2
   }
   ```

3. Run the helper:
   `bash "$CLAUDE_PLUGIN_ROOT/skills/sr-spec/scripts/coord_dep_scan.sh" "$SPEC_FILE" "${PREREQS[@]+"${PREREQS[@]}"}"`.
   Capture the JSON bundle.

4. **Trivial fast path** — only when `peers` is empty (or all
   overlaps map to parents already in `existing_blockers`) AND
   `prior_accepted_edges` is empty: write `[]` to the transport
   file (sub-step 7), emit `step 11: No coordination dependencies
   detected.`, and proceed to step 12. If `prior_accepted_edges`
   is non-empty, **do NOT take the fast path** — fall through to
   the operator gate so prior entries get re-audit consideration.

5. **Structured-prompt reasoning** over the new spec + each peer's
   title and description. Six-item checklist:

   1. List path-level surface for the new spec (files touched,
      restructured, renamed).
   2. Same for each peer.
   3. Report shared paths.
   4. For each shared path, judge collide vs. disjoint; keep only
      collisions.
   5. List identifier-level overlaps (function names, env vars,
      config keys).
   6. List rename/move overlaps (one moves/renames a file the
      other edits).

   Skip any peer already in `existing_blockers` (defensive
   re-check; the helper already filtered).

6. **Per-candidate operator gate.** Merge fresh-scan candidates
   with `prior_accepted_edges` (dedup by parent ID; for parents in
   both, present with the more recent rationale and note prior
   confirmation). For each candidate show: parent ID + title,
   source (fresh-scan / prior-accepted), category, one-line
   rationale. Three choices: **accept / reject / edit-rationale**.

   Rejecting a prior-accepted entry that's already in `INITIAL_BLOCKERS`
   means the relation stays in Linear without an audit comment —
   surface this consequence in the rejection prompt so the
   operator can manually remove the relation via Linear UI if
   they want.

7. **Persist `accepted_edges` to the transport file.** Format is
   an array of `{parent, rationale}` objects:

   ```json
   [{"parent": "ENG-X", "rationale": "..."}, ...]
   ```

   Always write the file (empty array `[]` when nothing accepted)
   so step 12 can distinguish "step 11 ran" (file exists) from
   "step 11 was bypassed" (file absent). Each Bash tool call in
   the skill is a fresh process — the file is the only reliable
   step-11→step-12 handoff.

   Add `/.sensible-ralph-coord-dep.json` to the plugin's
   `.gitignore` and to `docs/design/worktree-contract.md`'s
   "Required `.gitignore` entries" table. The file is
   per-worktree, ephemeral; successful finalize deletes it.

**Integration with finalize step 12.** Step 11 only stages
`accepted_edges` (in the transport file); step 12 absorbs the
writes into its existing sub-step 5 ("Push spec, set blockers,
verify"). Step 12's modified internal sequence:

1. **Read `accepted_edges` from the transport file.**

   ```bash
   COORD_DEP_FILE="$WORKTREE_PATH/.sensible-ralph-coord-dep.json"
   accepted_parents=()
   if [[ -f "$COORD_DEP_FILE" ]]; then
     # Validate file shape BEFORE consuming. A truncated /
     # hand-edited / corrupted file must abort finalize, not
     # silently approve the issue with no coord-dep audit.
     #
     # Shape contract: a JSON array of objects, each having a
     # 'parent' key. Empty array `[]` is valid (the trivial
     # fast-path case in step 11 sub-step 4 writes exactly this).
     # `jq -e` returns non-zero only on parse failure or boolean-
     # false / null result; the predicate below is a boolean so
     # we get a clean exit-code semantic.
     if ! jq -e 'type == "array" and all(.[]; type == "object" and has("parent"))' \
            "$COORD_DEP_FILE" >/dev/null 2>&1; then
       echo "step 12: $COORD_DEP_FILE is malformed (expected JSON array of {parent: ..., rationale: ...} entries) — aborting finalize." >&2
       echo "  Inspect or delete the file by hand before re-running /sr-spec." >&2
       exit 1
     fi
     # Extract parent IDs. Empty output for an empty array is
     # expected and fine — accepted_parents stays empty.
     parsed_parents=$(jq -r '.[].parent' "$COORD_DEP_FILE")
     while IFS= read -r p; do
       [[ -n "$p" ]] && accepted_parents+=("$p")
     done <<< "$parsed_parents"
   fi
   # If $COORD_DEP_FILE was absent, accepted_parents stays empty
   # — that's the "no step-11 dialogue ran" or "operator skipped
   # the scan" case, which is fine; finalize proceeds without
   # coord-dep writes.
   ```

   `accepted_parents` is the parent-ID projection; keep the file
   path bound to compose the audit comment with rationales later.

2. **Capture `INITIAL_BLOCKERS`** — current Linear `blocked-by`
   set. Needed in `EXPECTED` (sub-step 8) so re-spec's
   prior-session blockers are accepted as expected, not flagged
   as drift.

   ```bash
   INITIAL_BLOCKERS=$(linear_get_issue_blockers "$ISSUE_ID" | jq -r '.[].id' | sort -u)
   ```

3. **Push spec description** (existing finalize behavior).

4. **Compute `ADD_LIST`, walk it (relations BEFORE comment).**

   ```bash
   ADD_LIST=$(printf '%s\n' "${PREREQS[@]+"${PREREQS[@]}"}" "${accepted_parents[@]+"${accepted_parents[@]}"}" \
     | sort -u | comm -23 - <(printf '%s\n' "$INITIAL_BLOCKERS"))
   committed_parents=()
   for parent in $ADD_LIST; do
     if linear issue relation add "$ISSUE_ID" blocked-by "$parent"; then
       committed_parents+=("$parent")
     else
       # Surface to operator: retry / skip-this-edge / abort.
     fi
   done
   ```

   `comm -23` filters out anything already in `INITIAL_BLOCKERS`
   to avoid duplicate-add (Linear's CLI behavior on duplicates
   is unreliable across versions).

   Per-edge failure choices:
   - **retry**: re-attempt the same parent.
   - **skip-this-edge**: ONLY for parents from `accepted_parents`
     (coord-dep). Removes the parent from `accepted_parents` so
     the audit comment won't list it. **NOT offered for PREREQS**
     parents — silently dropping a semantic prereq would let an
     issue reach Approved without its required dependency edge,
     breaking `/sr-start`'s pickup rule. PREREQS failures get
     retry-or-abort only.
   - **abort finalize**: stop the loop. Audit comment has NOT
     been posted yet, so any added relations have NO audit trail
     — surface a recovery recipe per sub-step 6's failure path.

   Comment-LAST is deliberate: it eliminates the over-claim
   failure mode where a skipped edge's marker line would later
   become destructive delete authority during cleanup. The
   trade-off (comment-post failure leaves relations without an
   audit trail) is handled in sub-step 6.

5. **End-of-loop invariant** (when not aborted): every parent in
   `accepted_parents` is now in Linear — either pre-existing in
   `INITIAL_BLOCKERS` (operator re-confirmed prior) or in
   `committed_parents` (just added). Skipped parents have been
   removed from `accepted_parents`.

   If `accepted_parents` is empty after the loop: skip sub-steps
   6 and 7; fall through to verify.

6. **If `accepted_parents` is non-empty: post the audit comment.**

   Compose per "The audit-comment contract" above. Bullet lines
   list every parent in `accepted_parents`; the
   ` ```coord-dep-audit ` block lists the same parent IDs. The
   audit set is `accepted_parents` in full — both newly-added and
   prior-already-in-Linear — because cleanup needs to discover
   ALL of them.

   ```bash
   linear issue comment add "$ISSUE_ID" --body-file <tmp>
   ```

   **On comment-post failure:** newly-added relations are in
   Linear without an audit trail. Operator chooses:
   - **retry** — usually transient.
   - **proceed-anyway** — print the comment body inline; operator
     manually posts via Linear UI. Do NOT transition state. Issue
     stays `In Design`; transport file intact for next-run reload.
   - **rollback** — best-effort `linear issue relation delete` on
     each entry in `committed_parents` (this run's adds only;
     pre-existing prior-run relations are NOT touched). Issue
     stays `In Design`.

7. **If `accepted_parents` is non-empty: add the coord-dep label**
   via `linear_add_label`. Idempotent. On failure: log; continue.
   The comment is the load-bearing artifact for cleanup, not the
   label.

8. **Verify** — `EXPECTED == ACTUAL` over the union:

   ```bash
   EXPECTED=$(printf '%s\n' \
     "${INITIAL_BLOCKERS[@]+"${INITIAL_BLOCKERS[@]}"}" \
     "${PREREQS[@]+"${PREREQS[@]}"}" \
     "${accepted_parents[@]+"${accepted_parents[@]}"}" \
     | sort -u)
   ACTUAL=$(linear_get_issue_blockers "$ISSUE_ID" | jq -r '.[].id' | sort -u)
   ```

   On mismatch: STOP, do not transition state. (`accepted_parents`
   is the right set per sub-step 5's invariant — every entry is
   either in `INITIAL_BLOCKERS` or `committed_parents`.)

9. **Delete the transport file** on successful state transition:
   `rm -f "$COORD_DEP_FILE"`. If finalize fails before this point,
   the file persists for resume on the next `/sr-spec` run.

The `${arr[@]+"${arr[@]}"}` guard above expands to nothing on
empty arrays, avoiding bash 3.2's unbound-variable fault under
`set -u`.

### 5. `/close-issue` step 8 — cleanup helper

New file: `skills/close-issue/scripts/cleanup_coord_dep.sh`.

Inputs:

- Env: `$ISSUE_ID`, `$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL`.

Behavior:

Algorithm:

1. **Query audit-block-bearing comments** via `linear api` with
   `body.contains: "coord-dep-audit"` filter, `first: 250`. Refuse
   silent truncation (`pageInfo.hasNextPage == true` → exit 1).
   `linear issue comment list` is NOT used: it truncates at ~50
   with no cursor support (see `skills/prepare-for-review/SKILL.md`).

2. **Extract fenced blocks per-comment.** Iterate comments
   independently (base64-encoded one-line-per-comment output via
   `jq -r '... | @base64'` then `base64 -d` per iteration —
   handles bodies with embedded newlines safely). Run a fresh
   `awk` per comment so an unclosed ` ```coord-dep-audit ` fence
   in one comment cannot leak `flag=1` into the next.

   ```bash
   tmpdir=$(mktemp -d); trap 'rm -rf "$tmpdir"' EXIT
   comment_count=0
   while IFS= read -r body_b64; do
     [[ -n "$body_b64" ]] || continue
     comment_count=$((comment_count + 1))
     printf '%s' "$body_b64" | base64 -d | awk -v dir="$tmpdir" -v c="$comment_count" '
       /^```coord-dep-audit$/{n++; out=sprintf("%s/c%05d-block-%05d.json", dir, c, n); flag=1; next}
       /^```$/{flag=0; next}
       flag{print > out}
     '
   done < <(printf '%s' "$comments" | jq -r '.data.issue.comments.nodes[].body | @base64')

   fenced_block_count=$(find "$tmpdir" -maxdepth 1 -name 'c*-block-*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
   parents=$(
     for f in "$tmpdir"/c*-block-*.json; do
       [[ -f "$f" ]] || continue
       jq -r '.parents[]?' "$f" 2>/dev/null || true
     done | sort -u
   )
   ```

   Per-block jq with `2>/dev/null`: a single malformed block must
   not suppress valid `parents` from other well-formed blocks
   (a `jq -s` over concatenated blocks would reject the whole
   stream on the first parse error and is explicitly avoided).

3. **Distinguish "no audit data" from "malformed".** Use
   `fenced_block_count` (actual extracted blocks), NOT the GraphQL
   match count — the latter matches inline mentions of
   `coord-dep-audit` in backticks/prose which are not authority.

   ```bash
   if [[ -z "$parents" ]]; then
     if [[ "$fenced_block_count" -gt 0 ]]; then
       echo "cleanup_coord_dep: $fenced_block_count audit block(s) found but yielded zero parsable parents — KEEPING coord-dep label" >&2
       exit 1
     fi
     # Truly no audit blocks — clean fast path.
     linear_label_exists "$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL" 2>/dev/null && \
       linear_remove_label "$ISSUE_ID" "$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL" \
         || echo "cleanup_coord_dep: label removal skipped or failed — continuing" >&2
     exit 0
   fi
   ```

4. **Best-effort delete + post-delete classification.** Attempt
   delete on every marker-parent (Linear's relation-delete returns
   the same exit status for present-and-deleted, present-and-failed,
   and absent-from-the-start, so don't classify per-call). Then
   re-fetch blockers; any marker-parent still present is a real
   failure. (Pre-delete snapshot would misclassify a concurrent UI
   removal between our delete attempt and our re-fetch as a
   failure.)

   ```bash
   for p in $parents; do
     linear issue relation delete "$ISSUE_ID" blocked-by "$p" 2>/dev/null || true
   done

   final_blockers=$(linear_get_issue_blockers "$ISSUE_ID" | jq -r '.[].id' | sort -u) || {
     echo "cleanup_coord_dep: post-delete linear_get_issue_blockers failed — KEEPING label conservatively" >&2
     exit 1
   }
   real_failures=0
   for p in $parents; do
     printf '%s\n' "$final_blockers" | grep -qx "$p" && {
       echo "cleanup_coord_dep: $p still present after delete — real failure" >&2
       real_failures=$((real_failures + 1))
     }
   done
   ```

5. **Label removal gated on full success.** If any real failure,
   keep the label and exit 1 — after `Done` the normal close flow
   won't run again, so the persistent label is the operator's
   only signal that cleanup is incomplete.

   ```bash
   if [[ "$real_failures" -eq 0 ]]; then
     linear_label_exists "$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL" 2>/dev/null && \
       linear_remove_label "$ISSUE_ID" "$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL" \
         || echo "cleanup_coord_dep: label removal skipped or failed — continuing" >&2
     exit 0
   else
     echo "cleanup_coord_dep: $real_failures edge(s) still present; coord-dep label kept" >&2
     exit 1
   fi
   ```

`/close-issue` SKILL.md step 8 invokes the helper and treats
non-zero exit as log-and-proceed-to-worktree-teardown. Cleanup is
housekeeping; the merge + `Done` are the load-bearing mutations.

## Edge cases

- **No Approved peers in scope.** Helper emits `peers: []`; step 11
  fast-paths to "No coordination dependencies detected" (provided
  no `prior_accepted_edges`).
- **Operator declared a semantic `blocked-by` at design time AND scan
  finds overlap with that same parent.** `existing_blockers` includes
  design-time PREREQS, so the parent is filtered out of candidates.
  The semantic edge survives close (no marker comment, no cleanup);
  semantic edges should not be auto-cleaned.
- **Re-spec on an Approved issue.** Prior coord-dep edges are in
  `existing_blockers` (skipped by helper). Newly-discovered edges
  get a new audit comment. Both old and new comments persist;
  cleanup unions over all of them.
- **Linear API fails mid-scan.** Helper exits non-zero. Operator
  chooses: retry, skip step 11 (proceed to finalize without
  coord-dep writes; ENG-281 backstop catches missed edges later),
  or abort.
- **Malformed audit-block JSON in one comment.** Per-block parsing
  isolates it (other comments' valid blocks still extract). If
  EVERY block is malformed, cleanup keeps the label and exits 1.

## Testing

Three new bats files in the existing `lib/test/` harness. The
reasoning step itself is NOT unit-tested — it's Claude prose in
SKILL.md, reviewed via codex at spec time.

**`lib/test/linear_remove_label.bats`** — `lib/linear.sh` helper.
Asserts: idempotent removal of present label; no-op on absent;
clear diagnostic on missing workspace label; API-failure
propagation.

**`skills/sr-spec/scripts/test/coord_dep_scan.bats`** —
data-assembly helper. Asserts: `peers: []` for empty peer list;
peer descriptions verbatim in `peers[].description`;
`existing_blockers` is the union of Linear's current `blocked-by`
set with the design-time PREREQS positional args, deduplicated;
self-exclusion of `$ISSUE_ID` from `peers[]`; exit 2 on missing
spec-file path. Fixtures cover: full-description peer, empty-
description peer, peer list including `$ISSUE_ID` (self-exclude),
pre-existing blocker overlapping a peer.

**`skills/close-issue/scripts/test/cleanup_coord_dep.bats`** —
cleanup helper. Mocks `linear api`, `linear_get_issue_blockers`,
`linear_label_exists`, `linear issue relation delete`,
`linear_remove_label`. Asserts:
- Zero matching comments → label-remove still attempted (gated on
  `linear_label_exists`), exit 0.
- Multi-comment dedup (same parent in fenced blocks across
  multiple comments collapses to one delete).
- Bullet text or inline `coord-dep-audit` mention OUTSIDE a fenced
  block is NOT extracted (only the JSON block is authoritative).
- One-malformed-block-among-valid: malformed block silently
  skipped; valid block's parents still extracted and deleted.
- All-malformed-blocks: keep label, exit 1.
- `pageInfo.hasNextPage=true`: abort loud (exit 1).
- Per-comment awk isolation: unclosed fence in comment 1 does NOT
  consume comment 2's body; comment 2's valid block still
  extracts.
- Concurrent-UI A: parent absent pre and post → success, exit 0.
- Concurrent-UI B: parent present pre, delete call non-zero,
  absent in post-delete re-fetch → success (pre-delete state not
  consulted).
- Real failure: parent still present in post-delete re-fetch →
  exit 1, label kept.
- Workspace label missing on success path → label-remove skipped
  (logged), exit 0.
- GraphQL response-shape failure → non-zero exit (must NOT be
  masked as "no edges").

## Prerequisites

**None.** ENG-279 (per-issue branch lifecycle) is already `Done`
(landed at `fc6166a`). ENG-280 reads peer specs from Linear
descriptions, not from worktrees, so it does not depend on ENG-279's
data model — but the design assumes the per-issue lifecycle for
symmetry with ENG-281.

No `blocked-by` relations to declare for this issue.

## Out of scope

- The `/sr-start` preflight backstop scan — that's ENG-281,
  blocked-by this issue. ENG-281 reuses the same marker, label, and
  `/close-issue` cleanup; no further `/close-issue` change is needed
  when ENG-281 lands.
- Auto-removal of coord-dep edges on re-spec when a re-spec scan
  determines a prior edge no longer applies. Too risky — can't
  reliably distinguish "scan changed its mind" from "operator added
  this manually." Edges live until `/close-issue` cleans them up.
- Mechanical pre-filtering (regex extraction of paths or identifiers
  from spec markdown to focus reasoning). The scan stays
  reasoning-driven by design; the issue body explicitly rejects
  regex-based detection.
- Symmetric notification on the parent issue (a "you blocked this
  child" comment on the parent). Single-side audit trail (comment
  on the child) is sufficient; symmetric notification adds Linear
  write surface for marginal forensics value.
- Migration for issues already `Approved` before this lands (no
  scan was run on them at finalize time). The `/sr-start` backstop
  in ENG-281 covers this case.

## Known limitations (v1)

Surfaced by codex review and accepted as v1 trade-offs. ENG-281's
`/sr-start` preflight provides defense-in-depth for several of
these. File follow-up issues if they bite in practice.

- **Stale transport-file replay if step 11 is skipped.** Step 11
  may be skipped (label-preflight failure, scan helper failure,
  operator choice). Step 12 still consumes any existing transport
  file, with no freshness check tying it to the current run. A
  stale file from an aborted earlier run can be replayed when the
  operator skips this run's scan. Mitigation: operator awareness
  + visible transport-file path in skill prose. Future fix:
  stamp the file with a run-id or spec SHA, refuse to consume on
  mismatch.
- **Cleanup deletes by parent ID, not relation instance.** If an
  operator manually removes a coord-dep relation, then later
  re-adds the same parent ID as a SEMANTIC `blocked-by`, cleanup
  will delete the (semantic) relation at close time. Workaround:
  edit the audit comment's `parents` array (or remove the
  comment) before closing. Future fix: store Linear's relation
  IDs (returned by `relation add`) in the audit JSON and look up
  per-instance at cleanup.
- **Comment-post failure leaves no durable recovery trail.** If
  step 12's comment-post fails after some relation-adds succeed,
  the operator is offered retry / proceed-anyway-with-manual-recipe
  / rollback. Best-effort rollback that itself partially fails
  leaves residue with no automatic discovery — the recovery
  recipe is in the session log only. Future fix: persist a local
  recovery record that step 11 surfaces and reconciles on the
  next run.
- **Verify exact-set check treats benign concurrent UI adds as
  drift.** `ACTUAL == EXPECTED` requires set equality; a
  concurrent semantic-blocker add by a human between
  `INITIAL_BLOCKERS` capture and the post-add re-fetch makes
  `ACTUAL ⊃ EXPECTED` and currently aborts finalize. Mitigation:
  rare; operator can re-run finalize. Future fix: change verify
  to "every required parent is present" (subset, not equality).

## Acceptance criteria

1. New `userConfig` option `coord_dep_label` exists in
   `.claude-plugin/plugin.json` with default `ralph-coord-dep`,
   mirrored in `lib/defaults.sh`.
2. `lib/linear.sh::linear_remove_label` exists, follows the
   `linear_add_label` pattern, returns 0 on success or no-op-on-absent,
   non-zero on workspace-label-missing or API failure.
3. `skills/sr-spec/scripts/coord_dep_scan.sh` exists, takes the spec
   file path and design-time PREREQS as inputs, emits the documented
   JSON bundle on stdout, exits 0 on empty peers, 1 on Linear failure,
   2 on missing spec file.
4. `skills/sr-spec/SKILL.md` documents step 11 (operator-interaction-
   only; no Linear writes) and step 12's modified sub-step 5
   sequence per Component 4 above. Both sections explicitly state
   the defer-writes-to-finalize contract. Step renumbering:
   existing step 11 (finalize) → step 12; existing step 10 (codex)
   and earlier unchanged; informal "Spec self-review" / "User
   review gate" stay informal.
5. `skills/close-issue/scripts/cleanup_coord_dep.sh` implements
   the algorithm in Component 5 above. SKILL.md step 8 invokes
   the helper; step 9 (worktree teardown) is the renumbered
   existing step 8.
6. `skills/sr-start/scripts/lib/preflight_labels.sh::preflight_labels_check`
   includes `CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL` in
   `required_vars`. `skills/sr-start/SKILL.md` Prerequisites
   lists the new `ralph-coord-dep` workspace label setup command
   alongside `ralph-failed` and `stale-parent`.
7. `/.sensible-ralph-coord-dep.json` added to the plugin's
   `.gitignore` and to `docs/design/worktree-contract.md`'s
   "Required `.gitignore` entries" table.
8. New bats files per the Testing section. Existing bats coverage
   for `lib/linear.sh`, `lib/preflight_labels.sh`, and affected
   skills continues to pass.
9. End-to-end: after `/sr-spec` runs the scan and accepts edges
   on a test issue, a subsequent `/close-issue` removes all the
   audited edges and the label.
10. **One-off post-`/close-issue` for THIS issue:** rename
    ENG-280's Linear title from "Add hidden-dependency scan to
    /sr-spec to detect file overlap with existing approved specs"
    to "Add coord-dep scan to /sr-spec to detect file overlap
    with existing approved specs" via `linear issue update
    ENG-280 --title "..."` AFTER worktree teardown (Linear's
    auto-recomputed `.branchName` no longer matters then). Same
    treatment applies to ENG-281 when that issue closes, but
    ENG-280 owns only its own rename.
