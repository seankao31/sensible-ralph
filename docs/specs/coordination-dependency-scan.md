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
  step 11     coord-dep scan         ← NEW
                ├─ skills/sr-spec/scripts/coord_dep_scan.sh   (data assembly)
                ├─ structured-prompt reasoning (skill prose)   (judgment)
                └─ on accepted findings: linear issue relation add
                                         linear_add_label (once)
                                         linear issue comment add (one comment per scan run)
  step 12     finalize (description push, blocker verify, transition Approved;
              was step 11)

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

## The reserved marker

The cleanup parser is **strictly line-anchored** and requires the
marker to appear as the leading content of a markdown list-bullet
line:

```
- **coord-dep**: blocked-by ENG-NNN — <rationale>
```

The cleanup regex (the contract `cleanup_coord_dep.sh` enforces):

```
^- \*\*coord-dep\*\*:[[:space:]]+blocked-by[[:space:]]+ENG-[0-9]+
```

Mandatory leading `- ` (literal hyphen + space), then `**coord-dep**:`,
then `blocked-by` then `ENG-NNN`. No optional whitespace before the
`-`, no nested-bullet indentation, no alternate prose framing.

Lines that mention the marker in any other shape — inline prose
quoting it, regex/example tokens, indented code-fence content
without the leading `- ` bullet — are NOT treated as removal
targets. This is the deliberate trade-off: the format is restricted
enough that arbitrary commentary about the feature won't accidentally
mark a real edge for deletion.

**Residual risk** (documented, not designed around): a comment that
includes a fenced code block whose **first character on a line** is
`-` followed by `**coord-dep**:` (e.g., a markdown-rendered example
of an audit comment) WILL match the regex. The mitigation is
discipline: prose explaining the marker should escape it (e.g.,
`\\-` or use indented quoting `>`), and operator-facing docs/
comments should avoid showing a faithful audit-line example without
markup adjustments. A more aggressive sentinel (an opaque token
that never appears in prose) was considered and rejected — it would
trade away the human readability of audit comments for marginal
robustness against an unlikely accident.

The single source of truth for this format is the header comment of
`skills/sr-spec/scripts/coord_dep_scan.sh`, copied as a `## Marker
format` section into both `skills/sr-spec/SKILL.md` (step 11) and
`skills/close-issue/SKILL.md` (step 8) so each skill is
self-contained for a reader. `/sr-spec` (today) and `/sr-start`
once ENG-281 lands both produce the same format; `/close-issue`'s
cleanup uses the same regex regardless of which scan posted the
comment.

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

### 4. `/sr-spec` step 11 — reasoning and mutation (skill prose)

The skill's step 11 prose drives the rest:

1. **Label-existence preflight.** Before any mutation, verify that
   the configured `coord-dep` label exists in the workspace:

   ```bash
   linear_label_exists "$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL" || {
     echo "step 11: workspace label '$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL' missing. Create it once via the Linear UI or update the plugin config to name an existing label, then re-run /sr-spec. Skipping step 11 for now is acceptable — proceed to step 12 if the operator confirms (the /sr-start backstop in ENG-281 will catch missed edges later)." >&2
     # Operator chooses: create label and retry, or skip step 11 and proceed to step 12.
   }
   ```

   The check is duplicated here (rather than relying on `/sr-start`'s
   preflight) because `linear issue update --label` silently no-ops
   on an unknown label name. Without the duplicated check, an
   operator who upgrades the plugin and runs `/sr-spec` before any
   `/sr-start` would write coord-dep edges and audit comments
   without ever landing the visible label, leaving no operator
   signal if `/close-issue`'s cleanup later partially fails.

2. Run the helper:
   `bash "$CLAUDE_PLUGIN_ROOT/skills/sr-spec/scripts/coord_dep_scan.sh" "$SPEC_FILE" "${PREREQS[@]}"`.
   Capture the JSON bundle.

3. **Trivial fast path.** If `peers` is empty, or if every potential
   overlap maps to a parent already in `existing_blockers`, emit one
   line — `step 11: No coordination dependencies detected.` — and proceed
   to step 12 (finalize).

4. **Structured-prompt reasoning.** Present the new spec body and
   each peer's title + description and work the six-item checklist:

   1. For the new spec, list **path-level surface**: files mentioned
      with apparent edit intent (touched, restructured, renamed).
   2. For each peer, do the same.
   3. Report shared paths.
   4. For each shared path, judge **collide vs. disjoint** —
      overlapping sections vs. genuinely different parts of the same
      file. Keep only collisions.
   5. List **identifier-level overlaps**: function names, env vars,
      config keys mentioned in both with apparent code-touch intent.
   6. List **rename/move overlaps**: a peer renames or moves a file
      the new spec edits, or vice versa.

   Skip any peer in `existing_blockers`. The helper has already
   filtered, but the reasoning step re-checks defensively (covers
   the case where the operator added a relation manually mid-dialogue
   between the helper run and this step).

5. **Per-candidate operator gate.** For each surviving candidate,
   show: parent ID + title, category (`path-collide` / `identifier`
   / `rename`), one-line rationale. Three choices:
   **accept / reject / edit-rationale**.

6. **If accepted candidates is empty:** skip the rest of step 11
   and proceed to step 12 (finalize). No comment, no label, no
   relations to add.

7. **Post the audit comment FIRST, BEFORE any relation-adds.**

   - Build `accepted_edges` from the accepted candidates (each is
     `{parent, rationale}`).
   - Compose one consolidated comment in the format below, listing
     every entry in `accepted_edges`.
   - `linear issue comment add "$ISSUE_ID" --body-file <tmp>`.
   - **If comment-post fails: ABORT step 11.** Print the comment body
     inline so the operator can manually post if they want, but do
     NOT proceed to relation-add. The operator's choices: retry the
     comment-post, abort the scan entirely (no edges added, no
     leakage), or proceed-anyway (operator manually posts the
     comment, then re-runs step 11 starting at sub-step 7 above).
   - If comment-post succeeds: continue to sub-step 8 (relation-adds).

   Why comment-first: `/close-issue`'s cleanup is the ONLY mechanism
   that finds and removes coord-dep edges. If a relation-add lands
   but the comment doesn't, `/close-issue` has no source of truth to
   discover the edge, and it leaks into the relation graph
   permanently. Posting the comment first makes the audit trail the
   load-bearing artifact: if it doesn't land, no edges land either.
   Inversely, if a later relation-add fails, the comment may
   overstate — `/close-issue`'s cleanup tolerates that gracefully
   (it walks marker comments, attempts delete, and treats genuine
   "edge absent" as benign).

8. **After successful comment-post, walk accepted candidates and
   add relations.** For each `{parent, rationale}` in
   `accepted_edges`:

   - `linear issue relation add "$ISSUE_ID" blocked-by "$parent"`.
   - On success: append `$parent` to a NEW in-shell array
     `SCAN_ADDED_EDGES` (kept SEPARATE from `PREREQS`; see the
     finalize-integration callout below) and append `{parent,
     rationale}` to local `committed_edges`.
   - On failure: surface the error to the operator with three
     choices — **retry / skip-this-edge / abort step 11**.
     - **retry**: re-attempt `linear issue relation add` for the
       same parent.
     - **skip-this-edge**: REMOVE `$parent` from `accepted_edges`
       entirely. Semantically: the operator is changing their mind
       and rejecting the edge in light of the failure. The audit
       comment will over-claim (it lists this edge under the
       `**coord-dep**` heading), but `/close-issue`'s cleanup
       tolerates that gracefully via the "edge absent (benign)"
       partition (described in Section 5 below).
     - **abort step 11**: stop the loop with no further mutations.
       `/sr-spec` exits step 11 in a partial state. The operator's
       responsibility to either re-run `/sr-spec` (which detects
       In Design and resumes; the next scan re-proposes the
       partially-added edges since they're not yet in
       Linear-blocked-by) or to manually clean up.

   **Invariant after sub-step 8 completes:** `accepted_edges ==
   committed_edges` (modulo any edge the operator chose to skip,
   which is removed from BOTH arrays). This invariant is what makes
   finalize sub-step 5's verification correct. The skill prose at
   step 11 MUST NOT silently swallow relation-add failures — doing
   so would let an Approved issue land with operator-confirmed
   coord-dep edges missing from Linear, breaking the sequencing
   guarantee this feature is supposed to provide.

9. **Add the label.** `linear_add_label "$ISSUE_ID" "$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL"`.
   Idempotent — labels are additive in `lib/linear.sh::linear_add_label`.
   On failure: log; continue. The comment is the load-bearing
   artifact, not the label.

**Comment format** (Approach C — one consolidated comment per scan
run, marker repeats per line):

```
**coord-dep** edges added by /sr-spec scan:

- **coord-dep**: blocked-by ENG-X — both restructure `lib/scope.sh`'s `_scope_load` function
- **coord-dep**: blocked-by ENG-Y — ENG-Y renames `foo.sh` which this spec edits inline

Will be removed automatically on `/close-issue`.
```

Each line independently parseable by the cleanup helper's regex.
Multiple comments accumulate fine across re-spec sessions.

**Critical integration with finalize step 12.** Two arrays must
stay separate end-to-end:

- **`PREREQS`** — design-time prerequisites (set by the operator at
  step 6 of the dialogue). Finalize sub-step 5's add-loop iterates
  this array and calls `linear issue relation add` for each.
  Step 11 must NOT mutate this array.
- **`SCAN_ADDED_EDGES`** — parents the step-11 scan accepted AND
  successfully added at step 11. Finalize sub-step 5 does NOT
  iterate this array for relation-adds (the relations are already
  in Linear); it only contributes to verification.

Finalize sub-step 5's existing verification logic — currently
`EXPECTED=$(printf '%s\n' "${PREREQS[@]}" | sort -u)` — must be
modified to compute `EXPECTED` over the **union** of `PREREQS` and
`SCAN_ADDED_EDGES`:

```bash
EXPECTED=$(printf '%s\n' "${PREREQS[@]}" "${SCAN_ADDED_EDGES[@]+"${SCAN_ADDED_EDGES[@]}"}" | sort -u)
```

The `${arr[@]+"${arr[@]}"}` pattern expands to nothing when the
array is empty, sidestepping bash 3.2's unbound-variable fault
under `set -u`. (Same pattern `lib/linear.sh::linear_add_label`
uses.)

Why this separation matters: if step 11 appended to `PREREQS`,
finalize's add-loop would attempt to re-add scan-discovered edges
that are already in Linear. Linear's CLI behavior on duplicate
relation-add is unreliable to depend on (some versions error,
some no-op), and even silent no-op masks a real contract muddle.
Keeping the arrays separate makes the responsibility crisp:
PREREQS owns "needs to be added at finalize," `SCAN_ADDED_EDGES`
owns "already added at step 11," and `EXPECTED` is just the union
for verification. Implementers MUST NOT collapse the two arrays.

Call this contract out explicitly in the SKILL.md prose at both
step 11 (where `SCAN_ADDED_EDGES` is populated) and step 12
(where `EXPECTED` is computed over the union).

### 5. `/close-issue` step 8 — cleanup helper

New file: `skills/close-issue/scripts/cleanup_coord_dep.sh`.

Inputs:

- Env: `$ISSUE_ID`, `$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL`.

Behavior:

```bash
# 1. Server-side query for comments containing the marker. linear's
#    `issue comment list` CLI returns only the first ~50 comments
#    with no cursor flag exposed (see skills/prepare-for-review/SKILL.md
#    for the same constraint), so on long-lived issues older
#    coord-dep comments would be silently invisible. Use `linear api`
#    with a body.contains filter instead — same pattern
#    /prepare-for-review uses for its dedup check.
comments=$(linear api \
  --variable "issueId=$ISSUE_ID" \
  --variable "marker=**coord-dep**:" <<'GRAPHQL'
query($issueId: String!, $marker: String!) {
  issue(id: $issueId) {
    comments(filter: { body: { contains: $marker } }, first: 250) {
      pageInfo { hasNextPage }
      nodes { body }
    }
  }
}
GRAPHQL
) || {
  echo "cleanup_coord_dep: failed to query comments on $ISSUE_ID — skipping cleanup" >&2
  exit 1
}

# 2. Refuse silent truncation. 250 marker-matching comments on a
#    single issue is implausible; if it ever happens, fail loud
#    rather than work from incomplete data — the same posture
#    `linear_get_issue_blockers` and `linear_label_exists` take.
has_next=$(printf '%s' "$comments" | jq -r '.data.issue.comments.pageInfo.hasNextPage // false')
if [[ "$has_next" == "true" ]]; then
  echo "cleanup_coord_dep: marker-comment query truncated for $ISSUE_ID at 250 — aborting cleanup; investigate manually" >&2
  exit 1
fi

# 3. Line-anchored extraction across the matching comment bodies,
#    dedup. The sed expression enforces the contract from "The
#    reserved marker" section: literal leading `- ` bullet, then
#    the marker pattern. Lines that don't match this exact shape
#    are NOT treated as removal targets, even if they contain the
#    marker text inline. The capture group extracts ONLY the
#    parent-ID immediately after `blocked-by`, so any incidental
#    `ENG-NNN` references in the rationale (e.g. "overlaps with
#    ENG-Y's restructure") are NOT mistaken for parent IDs.
#
#    sed with `-n` + `p` outputs only matched lines; returns 0
#    even on zero matches, so no `|| true` guard is needed.
parents=$(printf '%s' "$comments" | jq -r '.data.issue.comments.nodes[].body' \
  | sed -nE 's/^- \*\*coord-dep\*\*:[[:space:]]+blocked-by[[:space:]]+(ENG-[0-9]+).*/\1/p' \
  | sort -u)

# Fast path: no marker matches → no edges to remove. Still attempt
# label-remove (idempotent) and exit 0.
if [[ -z "$parents" ]]; then
  linear_remove_label "$ISSUE_ID" "$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL" \
    || echo "cleanup_coord_dep: label removal failed (no edges to delete) — continuing" >&2
  exit 0
fi

# 4. Best-effort delete loop — try to delete every marker-parent.
#    Linear's relation-delete returns the same exit status whether
#    the edge was present-and-deleted, present-and-failed, or
#    absent-from-the-start, so we don't try to classify here. We
#    just attempt all deletes and let the post-delete state speak
#    for itself.
for p in $parents; do
  linear issue relation delete "$ISSUE_ID" blocked-by "$p" 2>/dev/null || true
done

# 5. Re-fetch blockers AFTER the delete loop. The post-delete state
#    is the ground truth — pre-fetch snapshots can go stale under
#    concurrent Linear UI edits (a human removing the relation
#    between our pre-fetch and our delete would otherwise be
#    misclassified as a real failure). Any marker-parent still in
#    blockers IS a real failure.
final_blockers_json=$(linear_get_issue_blockers "$ISSUE_ID") || {
  echo "cleanup_coord_dep: linear_get_issue_blockers (post-delete) failed for $ISSUE_ID — cannot verify cleanup state; KEEPING coord-dep label conservatively" >&2
  exit 1
}
final_blockers=$(printf '%s' "$final_blockers_json" | jq -r '.[].id' | sort -u)

real_failures=0
for p in $parents; do
  if printf '%s\n' "$final_blockers" | grep -qx "$p"; then
    echo "cleanup_coord_dep: $p still present in blockers after delete attempt — real failure" >&2
    real_failures=$((real_failures + 1))
  fi
done

# 6. Label removal — only if every marker-parent is absent from the
#    final post-delete state. Removing the label after partial
#    failures would erase the only signal that cleanup is
#    incomplete (the issue is already in Done at this point, so
#    the normal close flow won't run again, and the persistent
#    label is the operator's signal to investigate).
if [[ "$real_failures" -eq 0 ]]; then
  linear_label_exists "$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL" 2>/dev/null && \
    linear_remove_label "$ISSUE_ID" "$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL" \
      || echo "cleanup_coord_dep: label removal skipped or failed (label may not exist in workspace) — continuing" >&2
  exit 0
else
  echo "cleanup_coord_dep: $real_failures edge(s) still present after delete attempt; coord-dep label intentionally kept so the operator can see incomplete cleanup. Investigate and clear manually." >&2
  exit 1
fi
```

Five properties guaranteed:

- **Server-side filtered, no truncation surprise.** The
  `body.contains` filter on `**coord-dep**:` returns only matching
  comments — typically 0 or a small handful per issue (one per
  scan-run that found edges). The CLI's first-50 page limit is
  bypassed entirely. The hard 250 ceiling is a sanity bound on the
  filter result, not on total comments.
- **Multi-comment safe.** All matching comments walked; all parent
  IDs collected into one set before any delete is attempted. N
  re-spec runs producing N comments → all parents handled in one
  pass.
- **Idempotent under concurrent UI edits.** Failure classification
  is computed from the **post-delete blocker state** via a fresh
  re-fetch, NOT from a pre-delete snapshot. If a human removes a
  relation in Linear between our delete attempt and our re-fetch,
  cleanup correctly classifies that parent as absent (cleanup
  complete). If a relation is still present after our delete
  attempt, that's a real failure regardless of when it was
  introduced.
- **Label kept on real failure.** If any marker-parent is still in
  the blocker set after the delete loop, the `ralph-coord-dep`
  label stays on the issue and the script exits non-zero. After
  the `Done` transition the normal close flow won't run again, so
  this persistent label is the operator's only signal that
  something needs hand-cleanup.
- **Zero-match safe under `set -euo pipefail`.** The sed extraction
  returns 0 even on no matches (no need for `|| true`); the
  no-marker-comments path is the common case for issues without
  any coord-dep history and exits cleanly with the label-remove
  attempt.

**Documented edge case (not designed around):** if an operator
manually removes a coord-dep relation, then later re-adds the same
parent ID as a SEMANTIC `blocked-by` relation, this cleanup will
delete the (semantic) relation when the issue closes. The marker
comment is the only provenance signal cleanup uses, and it doesn't
encode "when this edge was added vs. removed." Workaround for
operators repurposing a relation: also delete the corresponding
marker line from the audit comment by hand. Cost-of-fixing this
algorithmically (e.g., per-edge timestamps in the marker, or
mutating the audit comment when the relation is removed) outweighs
the value — the scenario is rare and requires deliberate operator
action that happens to match this specific pattern.

`/close-issue`'s SKILL.md step 8 invokes the helper:

```bash
bash "$CLAUDE_PLUGIN_ROOT/skills/close-issue/scripts/cleanup_coord_dep.sh" \
  || echo "close-issue: coord-dep cleanup returned non-zero; proceeding to worktree teardown" >&2
```

Cleanup is housekeeping; the merge + `Done` are the load-bearing
mutations and have already landed.

## Edge cases

- **No Approved peers in scope.** Helper emits `peers: []`; skill
  prose fast-paths to "No coordination dependencies detected." Step 11
  completes silently.
- **Operator declared a logical `blocked-by` at design time AND scan
  finds path overlap with that same parent.** Helper's
  `existing_blockers` includes the design-time PREREQS (passed as
  positional args), so the parent is excluded from candidates. No
  re-proposal, no second comment. The logical edge stays semantic;
  no marker comment, no label, no `/close-issue` cleanup of that
  edge — semantic edges survive close, as they should.
- **Re-spec on an Approved issue (state-matrix `Approved` row).**
  The current issue's prior spec exists on its branch + as Linear
  description. Coord-dep edges from the prior session are already
  in `blocked-by`, so the helper's `existing_blockers` includes
  them; they're skipped. Newly-discovered edges (if any) get a new
  comment. Both old and new comments persist; `/close-issue` cleans
  up everything via the union over all comments.
- **Linear API fails mid-scan.** Helper exits non-zero; skill prose
  surfaces the failure. Operator chooses: retry the scan, skip step
  11 entirely (proceed to finalize without scan — finalize succeeds
  because `PREREQS` still has design-time edges), or abort the
  dialogue. Skipping step 11 is acceptable and supported, with a
  one-line warning logged to the operator's session output. The
  `/sr-start` backstop in ENG-281 will catch missed edges later.
- **Operator manually edits a prior coord-dep audit comment.** The
  marker regex still matches if the edit preserves the line format;
  edits that break the line format are picked up as zero matches and
  the corresponding edge stays at close. Document the marker as
  reserved; operators editing it bear consequences. Not a
  high-priority risk.
- **Marker text appears in a code fence inside a comment.** The
  regex matches across fence boundaries; the cleanup helper would
  treat it as a removal target. Mitigation: document that the marker
  is reserved anywhere in any comment body. Risk of accidental match
  in normal prose is low (the literal `**coord-dep**:
  blocked-by ENG-NNN` prefix is unusual).

## Testing

Three new bats files, integrated into the existing `lib/test/`
harness:

1. **`lib/test/linear_remove_label.bats`** — unit-tests the new
   `lib/linear.sh` helper. Mocks `linear` CLI calls; asserts:
   idempotent removal of present label, no-op on absent label, clear
   diagnostic on missing-workspace-label, propagation of API
   failures.

2. **`skills/sr-spec/scripts/test/coord_dep_scan.bats`** —
   unit-tests the data-assembly helper. Mocks `linear` CLI for
   issue-list and issue-view; asserts:
   - Empty peer list emits valid JSON with `peers: []`.
   - Peer descriptions are passed through verbatim into the
     `peers[].description` field.
   - `existing_blockers` is the **union** of Linear's current
     `blocked-by` set (from `linear_get_issue_blockers`) and the
     design-time PREREQS passed as positional args, deduplicated
     and sorted. (It's a parent-ID list, NOT a filtered peer list:
     all Approved peers still appear in `peers[]` regardless; the
     reasoning step uses `existing_blockers` to skip candidates
     post-extraction.)
   - Self-exclusion: when Linear's peer list happens to include the
     current `$ISSUE_ID`, it is filtered out of `peers[]`.
   - Bad spec-file path returns exit 2.

3. **`skills/close-issue/scripts/test/cleanup_coord_dep.bats`** —
   unit-tests the cleanup helper. Mocks `linear api`,
   `linear_get_issue_blockers`, `linear_label_exists`,
   `linear issue relation delete`, and `linear_remove_label`.
   Asserts:
   - Zero matching comments → label-remove still attempted, exit 0
     (sed extraction returns 0 on no match without needing
     `|| true`).
   - Multi-comment dedup works (same parent in multiple matching
     comments collapses to one delete attempt).
   - Lines that mention the marker outside the leading-bullet form
     (inline prose, alternative indentation) are NOT extracted.
   - `pageInfo.hasNextPage=true` aborts loud (exit 1, label not
     removed).
   - Concurrent-UI scenario A: parent absent before delete attempt,
     stays absent after → cleanup classifies as success (no real
     failure recorded; label removed; exit 0).
   - Concurrent-UI scenario B: parent present before delete attempt,
     delete-call returns non-zero, parent IS absent in post-delete
     re-fetch → cleanup classifies as success (the pre-delete
     state isn't consulted; only the post-delete re-fetch
     matters).
   - Real failure: parent still present in post-delete re-fetch →
     real failure counted, label KEPT, exit 1.
   - All deletes succeed (post-delete re-fetch confirms all
     marker-parents absent) → label removed, exit 0.
   - Workspace label missing on the success path → label-remove
     skipped (logged); exit 0 because relation-deletes still
     completed cleanly.
   - GraphQL/`jq`-parse failure (e.g., malformed response shape)
     propagates as a non-zero exit — must NOT be masked by
     `|| true` guards or treated as "no edges to delete."

The reasoning step itself is **not** unit-tested — it's Claude prose
in `skills/sr-spec/SKILL.md`, not code. The structured-prompt
template is reviewed as part of the codex spec gate at step 11 of
the next time `/sr-spec` is run on a spec touching this surface.

The bats fixtures should include at least:

- A peer with full `docs/specs/...` description (typical case).
- A peer with empty description (edge case — counts as `peers[]`
  entry but reasoning trivially finds no overlap).
- Self-exclusion (peer list returned by Linear includes
  `$ISSUE_ID`).
- Pre-existing `blocked-by` edge that overlaps with a peer.

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
4. `skills/sr-spec/SKILL.md` documents step 11 with the
   structured-prompt checklist, the per-candidate operator gate, the
   mutation order (**audit comment posted FIRST; abort step 11
   entirely if comment-post fails — no relations are added on that
   path; only after comment-post succeeds, walk accepted candidates
   and add relations; finally add the label**), the **`PREREQS`
   vs. `SCAN_ADDED_EDGES` separation contract** with step 12 (step
   11 populates `SCAN_ADDED_EDGES` only — never mutates `PREREQS`;
   step 12's add-loop iterates only `PREREQS` while its verify
   compares ACTUAL to the union `PREREQS ∪ SCAN_ADDED_EDGES`), and
   the comment format. Step 12 (finalize) sub-step 5 is updated so
   `EXPECTED` is computed over that union. Step renumbering:
   existing step 11 (finalize) becomes step 12; existing step 10
   (codex) and all earlier numbers stay unchanged; informal "Spec
   self-review" and "User review gate" sections stay informal.
5. `skills/close-issue/scripts/cleanup_coord_dep.sh` exists and
   implements the cleanup contract:
   - Queries marker-matching comments via `linear api` with a
     `body.contains` filter (NOT via `linear issue comment list`,
     which truncates at ~50 with no cursor support).
   - Refuses silent truncation when `pageInfo.hasNextPage=true`
     (exit 1, label retained).
   - Extracts parent IDs via `sed -n ... p` with the line-anchored
     leading-bullet regex (see "The reserved marker" section).
     `sed` returns 0 on zero matches — no `|| true` guard, so a
     genuine `jq`/parser failure still propagates under
     `set -euo pipefail`.
   - Attempts `linear issue relation delete` on every extracted
     parent (best effort), then **re-fetches** blockers and
     classifies failure from the post-delete state — NOT from a
     pre-delete snapshot. This is deliberate: a pre-fetch goes
     stale under concurrent UI edits and misclassifies completed
     cleanup as failure. Implementers MUST NOT reintroduce the
     pre-fetch-snapshot pattern.
   - Verifies workspace label exists (via `linear_label_exists`)
     before attempting `linear_remove_label`; skips just the
     label-remove call if missing, while still doing relation
     deletes.
   - Removes the `coord-dep` label only when no marker-parent
     remains in the post-delete blocker set.
   - Exits 0 on a clean cleanup (every marker-parent absent in
     post-delete state); exits 1 on real-failure or unexpected
     truncation (signaling `/close-issue` to log; `/close-issue`
     proceeds to worktree teardown either way).
6. `skills/close-issue/SKILL.md` documents step 8 (cleanup) and
   step 9 (reap codex broker + remove worktree — was step 8). The
   new step's prose includes the marker format and the contract
   with the scan.
7. `skills/sr-start/scripts/lib/preflight_labels.sh::preflight_labels_check`
   includes `CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL` in `required_vars`.
8. `skills/sr-start/SKILL.md` Prerequisites lists the new
   `ralph-coord-dep` workspace-scoped label setup command alongside
   the existing `ralph-failed` and `stale-parent` ones.
9. New bats files cover the helpers per the testing section.
10. Existing bats coverage for `lib/linear.sh`, `lib/preflight_labels.sh`,
    and the affected skills continues to pass.
11. After `/sr-spec` runs the scan and accepts edges on a test issue,
    a subsequent `/close-issue` correctly removes all the marked
    edges and the label.
12. **One-off, post-`/close-issue`:** rename ENG-280's own Linear
    title from "Add hidden-dependency scan to /sr-spec to detect
    file overlap with existing approved specs" to "Add coord-dep
    scan to /sr-spec to detect file overlap with existing approved
    specs" via `linear issue update ENG-280 --title "..."`. This
    one-off step lands AFTER the worktree teardown in `/close-issue`
    step 9 — at that point Linear's auto-recomputed `.branchName`
    no longer matters because the branch+worktree are already gone.
    NOT a feature added to `/close-issue`'s automation; just a
    closing-checklist item specific to this issue. The same
    treatment applies to ENG-281 once that issue closes (its title
    is also "Add hidden-dependency backstop scan ..."), but ENG-280
    only owns the rename of its own title.
