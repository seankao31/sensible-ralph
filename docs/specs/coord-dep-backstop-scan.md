# Coordination-dependency backstop scan in `/sr-start`

**Linear:** ENG-281
**Spec base SHA:** `5d462694950db96577a7b3d58bdb5c5f1a0fd875`

## Goal

Detect coordination dependencies between Approved specs at `/sr-start`
preflight time as a defense-in-depth backstop to ENG-280's `/sr-spec`
primary scan. Surface candidate `blocked-by` edges to the operator
with reasoning, write accepted edges using the same `coord-dep-audit`
audit-comment format and `ralph-coord-dep` label that ENG-280 ships,
and pause until the operator has reviewed every proposal before
proceeding to `build_queue.sh`.

The detection is **reasoning-driven**, not regex-based, identical in
shape to ENG-280: the helper assembles data, skill prose reasons
about overlap and gates operator decisions, and Linear writes use
ENG-280's audit-comment contract verbatim so `/close-issue`'s
existing cleanup helper applies without modification.

## Symptoms this resolves

1. **Issues approved before ENG-280 landed** — no scan was run on
   them at finalize time, so coordination dependencies that exist in
   their specs are absent from the `blocked-by` graph. The
   orchestrator dispatches them in arbitrary toposort order and the
   second-to-land hits a merge conflict that smarter ordering would
   have prevented.
2. **Issues approved without `/sr-spec`** — manual finalize
   (description set via Linear UI, state transitioned by hand)
   bypasses ENG-280's scan entirely. Same dispatch-order failure
   mode.
3. **Coupling discovered after the fact** — ENG-280's scan compares
   a new spec against the Approved peers existing at finalize time.
   If spec C is approved later and reveals a coupling with already-
   approved A and B that A and B's pairwise scan never had cause to
   surface, only the dispatch-time backstop catches it.

ENG-280 explicitly notes that its scan does not migrate already-
Approved issues; this issue is the migration path. The backstop
also closes the manual-finalize gap, which ENG-280 cannot.

## Architecture

The scan inserts as a new **Step 2** in `skills/sr-start/SKILL.md`
between today's Step 1 (`preflight_scan.sh`) and today's Step 2
(`build_queue.sh`). Existing Steps 2/3/4 renumber to 3/4/5. The new
flow:

```
Step 1 — Pre-flight sanity scan         (unchanged)
Step 2 — Coordination-dependency scan   ← NEW
Step 3 — Build the ordered queue        (was Step 2)
Step 4 — Dry-run preview and confirmation  (was Step 3)
Step 5 — Dispatch via orchestrator      (was Step 4)
```

The scan runs **after** `preflight_scan.sh` because reasoning over
specs whose structural anomalies (missing PRD, canceled blockers,
out-of-scope blockers, etc.) have not been triaged is wasted effort
— Step 1 either clears the run or aborts before Step 2 begins. It
runs **before** `build_queue.sh` because `blocked-by` relations the
scan accepts must exist before toposort runs; otherwise the queue
would be built against an incomplete graph and require a re-run to
absorb the accepted edges.

```
                 ┌───────────────────────┐
                 │  Step 1: preflight    │  exit non-zero → STOP
                 └───────────┬───────────┘
                             │ all clear
                             ▼
                 ┌───────────────────────┐
                 │  Step 2: coord-dep    │
                 │  ┌─────────────────┐  │
                 │  │ helper          │  │  data assembly only
                 │  │ (no LR writes)  │  │
                 │  └────────┬────────┘  │
                 │           ▼           │
                 │  ┌─────────────────┐  │
                 │  │ skill prose:    │  │  reasoning,
                 │  │ candidates +    │  │  operator gate,
                 │  │ writes (LR)     │  │  per-child writes
                 │  └────────┬────────┘  │
                 └───────────┼───────────┘
                             │ all candidates reviewed,
                             │ writes verified
                             ▼
                 ┌───────────────────────┐
                 │  Step 3: build_queue  │
                 └───────────────────────┘
```

**No transport file.** ENG-280 needs a transport file
(`<worktree>/.sensible-ralph-coord-dep.json`) because its step 11
reasoning runs in a different shell process from step 12's finalize
mutations, and Bash tool calls don't share state across sessions.
ENG-281's scan/decisions/writes all happen in one SKILL.md step
inside one conversation; decisions live in conversation context
throughout and never need to cross a process boundary. The
transport-file pattern is not reused.

**Spec source.** The helper reads peer descriptions from Linear
(`linear issue view <id> --json`), not from worktrees, mirroring
ENG-280's choice. Approved-state issues are guaranteed to have a
description that matches their on-branch spec because `/sr-spec`'s
finalize sub-step 5 pushes the spec body verbatim into the
description, and mid-flight spec amendments via `/sr-implement`
only happen during `In Progress` (i.e., after `build_queue.sh`),
so for the Approved-vs-Approved comparison this scan performs the
descriptions are authoritative by construction.

## Components

### 1. Helper: `skills/sr-start/scripts/coord_dep_backstop_scan.sh`

Pure data assembly, no decisions, no Linear writes. Sibling to
ENG-280's `skills/sr-spec/scripts/coord_dep_scan.sh`; named
`coord_dep_backstop_scan.sh` (matching the issue's "backstop scan"
language) so a `grep coord_dep` in the repo distinguishes the two
without needing to inspect directories.

**Inputs:**

* No positional args. ENG-280's helper takes a new-spec path and
  PREREQS as anchor; ENG-281 has no anchor — the entire Approved
  set is symmetric, all peers are simultaneously candidate children
  and candidate parents.
* Env: `$SENSIBLE_RALPH_PROJECTS`,
  `$CLAUDE_PLUGIN_OPTION_APPROVED_STATE`,
  `$CLAUDE_PLUGIN_OPTION_FAILED_LABEL` — same env consumed by
  `linear_list_approved_issues` callers.

**Behavior:**

1. Source `lib/linear.sh` and `lib/scope.sh` defensively (idempotent
   if already sourced — the skill is expected to have sourced both
   from Step 1's invocation context, but the helper does not assume
   it).
2. List Approved peers via `linear_list_approved_issues`. This is
   the same filter `build_queue.sh` uses (Approved state, no
   `ralph-failed` label, in scope) so the scan and dispatch see
   identical peer sets.
3. For each peer:
   * `linear issue view <id> --json --no-comments | jq -r '...'` —
     capture title and description verbatim. `--no-comments` keeps
     payloads tight (peer comments aren't reasoning input).
   * `linear_get_issue_blockers <id> | jq -r '.[].id'` — capture
     existing `blocked-by` parent IDs regardless of those parents'
     state. The relationship-existence signal is what matters here,
     not whether the parent is currently dispatchable; an
     A-blocked-by-B-Canceled pair is already sequenced (or
     deliberately NOT sequenced) by the operator, and surfacing it
     as a candidate would re-litigate a decision the operator
     already made.
4. Emit a single JSON object on stdout:

   ```json
   {
     "approved": [
       {
         "id": "ENG-A",
         "title": "...",
         "description": "<full body, verbatim>",
         "existing_blockers": ["ENG-X", "ENG-Y"]
       },
       {
         "id": "ENG-B",
         "title": "...",
         "description": "...",
         "existing_blockers": []
       }
     ]
   }
   ```

**Failure modes (all return non-zero, with stderr diagnostics):**

* `linear_list_approved_issues` failure → exit 1.
* Any `linear issue view` or `linear_get_issue_blockers` failure
  for a peer → exit 1, naming the offending peer ID. Fail-fast over
  emit-partial: silently dropping a peer would silently miss its
  overlaps, defeating the step's purpose.
* Empty Approved set OR singleton Approved set → emit valid JSON
  with the (possibly empty or singleton) `approved` array, exit 0.
  The helper does NOT short-circuit "fewer than 2 peers" itself;
  the skill prose handles the fast-path message in Step 2 sub-step 3.

**Cost note in the script's header comment:** O(N) Linear CLI calls
per scan, where N = Approved-set size. Each peer is two CLI calls
(view + blockers); typical N ≤ 10, so total wall-clock is
5–15 seconds. Same back-of-envelope as `preflight_scan.sh`.

The helper does NOT pre-compute candidate pairs in shell. Pre-
computing would mean either re-implementing the covered-pairs
filter in two languages (here and in skill prose for the operator-
facing display) or shipping a `pairs` array in the JSON that skill
prose then has to trust. Cleaner: emit the raw graph; let skill
prose compute the candidate set as part of constructing the
reasoning prompt, with the filter visible in the conversation
transcript.

### 2. Step 2 sub-steps 1–3 — recovery, invocation, fast paths

The new Step 2 of `skills/sr-start/SKILL.md` documents the following
sub-step sequence in prose. Sub-step 1 is recovery from any prior
run's partial-write residue; 2–3 are setup; 4–5 are reasoning +
operator gate; 6–7 are writes + verification.

No just-in-time label-existence check sits inside Step 2 itself.
ENG-280's `preflight_labels.sh::preflight_labels_check` already
includes `CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL` in `required_vars`,
so Step 1 (`preflight_scan.sh`) is guaranteed to abort the run
before Step 2 begins if the workspace label is missing.

**Sub-step 1 — orphan-relation recovery from prior runs.**

The recovery file `<repo>/.sensible-ralph/coord-dep-recovery.json`
records `(child, parent, rationale)` triples whose relation-add
landed in Linear during a prior `/sr-start` Step 2 but whose audit
comment did NOT (per-edge abort, per-comment partial-rollback). The
file is the **durable provenance record** that makes orphan
recovery survive across runs — without it, the next scan's
covered-pairs filter (sub-step 4) would see the orphan relation in
`existing_blockers` and fast-path the pair, leaving the relation
unauditable for `/close-issue` cleanup forever.

Schema:

```json
{
  "orphans": [
    {
      "child": "ENG-A",
      "parent": "ENG-B",
      "rationale": "<one-line text from the original gate decision>",
      "added_at": "2026-05-04T12:00:00Z"
    }
  ],
  "verify_drift": [
    {
      "child": "ENG-C",
      "newly_added_parents": ["ENG-D", "ENG-E"],
      "expected_blockers": ["ENG-F", "ENG-D", "ENG-E"],
      "actual_blockers": ["ENG-F", "ENG-D", "ENG-E", "ENG-G"],
      "audit_comment_posted": true,
      "label_added": true,
      "drifted_at": "2026-05-04T12:00:00Z"
    }
  ]
}
```

`orphans` and `verify_drift` are independent arrays; either may
be empty. Reading sub-step 1 must validate both shapes.

Path: `<repo-root>/.sensible-ralph/coord-dep-recovery.json`. The
`.sensible-ralph/` directory is gitignored repo-wide. It is
typically created by `orchestrator.sh` (Step 5) and `build_queue.sh`
(Step 3) via their existing `mkdir -p` calls, but on a first-ever
`/sr-start` run those scripts haven't executed yet by the time
sub-step 5/7 might need to write the recovery file. Skill prose
must `mkdir -p "$REPO_ROOT/.sensible-ralph"` before the first
write; subsequent runs find the directory already in place.

**Atomic writes.** All writes to `$RECOVERY_FILE` use the
temp-file + rename pattern so a partial write or interrupted
process cannot leave malformed JSON:

```bash
tmp="$RECOVERY_FILE.tmp.$$"
printf '%s\n' "$new_content_json" > "$tmp"
mv "$tmp" "$RECOVERY_FILE"   # atomic on same filesystem
```

Under normal operation, malformed JSON cannot arise. If it
somehow does (operator hand-edited, disk full mid-write before
atomic-rename hardening landed, etc.), the spec deliberately
does NOT offer a "delete and proceed" recovery — that would
silently lose orphan triples and let the relations they
describe slip through covered-pairs filtering forever. The
operator's recovery is one of:

* Inspect and repair the JSON shape by hand; re-run `/sr-start`.
* Manually walk Linear's `ralph-coord-dep`-labeled children,
  cross-reference each child's `blocked-by` relations against
  the parent IDs in their `coord-dep-audit` comments, and
  rebuild the orphan list from the diff. The operator then
  writes the recovered list to the file and resumes.

The skill prose surfaces both options; auto-deletion is NOT
offered. This is a deliberate friction point: a malformed
recovery file means cleanup-trail integrity is at risk, and
the operator must consciously address it.

Recovery flow (run before sub-step 2's helper invocation):

```bash
RECOVERY_FILE="$REPO_ROOT/.sensible-ralph/coord-dep-recovery.json"
if [[ -f "$RECOVERY_FILE" ]]; then
  # Validate BOTH orphans and verify_drift array shapes; either
  # may be empty but both keys must exist with array values.
  if ! jq -e 'type == "object"
              and has("orphans") and (.orphans | type == "array")
              and has("verify_drift") and (.verify_drift | type == "array")' \
       "$RECOVERY_FILE" >/dev/null 2>&1; then
    echo "step 2: $RECOVERY_FILE is malformed — manual repair required (do NOT delete; orphan triples and drift records would be lost)" >&2
    echo "  Recovery options:" >&2
    echo "    1. Hand-repair the JSON shape and re-run /sr-start." >&2
    echo "    2. Manually rebuild the orphan list by cross-referencing each ralph-coord-dep-labeled child's blocked-by relations against the parent IDs in its coord-dep-audit comments; write the diff into a fresh recovery file." >&2
    exit 1
  fi

  orphan_count=$(jq '.orphans | length' "$RECOVERY_FILE")
  if [[ "$orphan_count" -gt 0 ]]; then
    echo "step 2: $orphan_count orphan relation(s) from prior run(s) need audit-comment repair" >&2
    # Group orphans by child; for each child, attempt to compose
    # and post the audit comment now (idempotent — if a comment
    # already exists from a prior repair attempt, posting another
    # is harmless; cleanup unions over all matching audit blocks).
    # On per-child success, remove that child's entries from the
    # file. On failure, keep entries and surface to operator at
    # end of recovery sub-step.
    ...
  fi
fi
```

The repair attempt is the same compose-and-post sequence sub-step
6 uses for fresh writes, just operating on triples loaded from the
file rather than from the gate. After repair:

* All orphans for child X repaired → remove X's entries from
  `$RECOVERY_FILE.orphans` (atomic write per the temp+rename
  pattern). If both `$RECOVERY_FILE.orphans` AND
  `$RECOVERY_FILE.verify_drift` are empty, delete the file.
* Some orphans for child X failed repair (Linear API failure,
  comment-post error) → keep X's entries; surface to operator;
  proceed with normal scan (the unrepaired relations are still in
  `existing_blockers`, sub-step 4 will fast-path them, but the
  operator now has a visible record they can act on next run).
* Any operator abort during recovery → exit Step 2; do NOT
  proceed to Step 3.

**Verify-drift surfacing.** If `$RECOVERY_FILE.verify_drift` is
non-empty, list each entry to the operator as informational
output (child ID, expected vs. actual blocker sets,
audit-comment-posted boolean, drifted_at timestamp). No
auto-action: drift records are observability artifacts, not
orphans (the audit trail is intact for committed parents). The
operator can clear drift records after investigating — the
recipe is documented in Component 6 (sub-step 7). Drift
surfacing does NOT block proceeding to sub-step 2.

Recovery completes BEFORE the helper runs. If the file is empty or
absent (the common path), recovery is a no-op.

**Sub-step 2 — run the helper.**

```bash
SCAN_JSON=$("$SKILL_DIR/scripts/coord_dep_backstop_scan.sh") || {
  # Operator chooses: retry / skip Step 2 (proceed to Step 3 with no
  # scan; ENG-280 covered most edges already at /sr-spec time) / abort.
  ...
}
```

**Sub-step 3 — trivial fast paths.**

* If `.approved | length` is 0 or 1 (no pairs possible): emit
  `step 2: No coordination dependencies detected.` and proceed
  directly to Step 3.
* If after candidate-pair filtering (sub-step 4) every pair is
  already covered by `existing_blockers`: emit the same one-line
  summary and proceed.

Both empty-output paths satisfy acceptance criterion 5.

### 3. Step 2 sub-step 4 — reasoning over the bundle

Skill prose constructs the reasoning prompt from `SCAN_JSON`. The
prose is responsible for:

1. **Compute the covered-pairs set in prose.** A pair `(A, B)` is
   covered if `B ∈ A.existing_blockers` OR
   `A ∈ B.existing_blockers`. Candidate pairs are all unordered
   pairs `{A, B}` where neither direction is covered. Self-pairs
   are excluded by construction. To generate each unordered pair
   exactly once, sort the Approved set by **numeric suffix** of
   the Linear ID (so `ENG-9 < ENG-50 < ENG-281`, not the string-
   lexicographic order which would put `ENG-281 < ENG-9`), and
   iterate `(approved[i], approved[j])` for `i < j`.
2. **Seven-item checklist per candidate pair, applied bundle-wide
   in one prompt** — extends ENG-280 step 11 sub-step 5's six
   items with an open-ended seventh item so coordination
   dependencies that don't fit the path/identifier/rename mental
   model are still surfaced for direction selection. Repeated
   per candidate pair:
   1. Path-level surface for spec A (files touched, restructured,
      renamed).
   2. Same for spec B.
   3. Shared paths between A and B.
   4. For each shared path: collide vs. disjoint section.
   5. Identifier-level overlaps (function names, env vars, config
      keys, label names).
   6. Rename/move overlaps (one moves/renames a file the other
      edits).
   7. **Any other sequencing dependency or shared invariant** not
      captured by 1–6: behavior changes the other depends on,
      test fixtures or helpers both modify, hooks one introduces
      that the other consumes, contract changes (e.g., return-
      type or argument-list changes to a function the other
      calls), shared workflow assumptions (e.g., one skill's
      output format that another skill parses). Surface each
      with a one-line rationale even if it doesn't fit the path/
      identifier/rename categories. Direction selection (rules
      1-3 below) applies the same way to these surfaces — rule
      3 (catch-all) handles direction when the introducer/
      consumer asymmetry is unclear.

   ENG-281's seventh item is a **strict superset** of ENG-280's
   six-item list. ENG-280's spec is frozen; if this expansion
   proves necessary in practice, ENG-280's checklist can be
   extended in a follow-up issue without breaking the audit
   contract (the contract is the `coord-dep-audit` JSON block,
   not the reasoning-prompt structure).
3. **Direction heuristic — total ordering, deterministic.** Each
   surfaced overlap commits to one `(child, parent)` direction
   with a one-line rationale. The heuristic is a total ordering;
   apply the **first matching rule** and stop:
   1. **Rename-before-edit, one-sided:** exactly one spec renames
      or moves a file the other edits. The renamer is parent
      (rename lands first; edit rebases onto new path).
   2. **Interface-before-use, one-sided:** exactly one spec
      introduces an identifier (function, env var, config key,
      label name) the other consumes. The introducer is parent.
   3. **All other surfaced overlaps:** numeric-suffix tiebreaker
      — the smaller Linear-ID suffix is parent. This rule is the
      unconditional final fallback and explicitly covers:
      * Mutual renames (both rename, of any files).
      * Mutual interface introductions (both introduce
        identifiers the other consumes).
      * Mixed conflicting rename/interface evidence (one side
        renames, other side introduces).
      * Same-section path collisions with no rename/interface
        signal.
      * **Identifier-only collisions where neither side
        introduces** (both modify an existing config key, env
        var, or function contract; both reference a shared
        identifier without claiming ownership). This subclass
        deserves a callout because it doesn't fit the rename-or-
        introduce mental model — when neither spec asserts "I
        own this," there's no semantic basis for direction at
        all.
      * Any other overlap the reasoning prompt surfaces that
        rules 1 and 2 do not match.

      The rationale MUST enumerate the evidence (rename, interface,
      identifier-modification, section-collision) on both sides
      so the operator sees the choice was a tiebreak, not an
      asymmetry the reasoning failed to detect: e.g., `Both
      modify CLAUDE_PLUGIN_OPTION_FOO; neither introduces it;
      numeric-suffix tiebreaker (100 < 200).`

   Two reasoning passes over identical bundles produce identical
   proposals because every rule reduces to a deterministic
   function of the spec content. Rule 3 is the catch-all by
   design; if a future overlap category emerges that is genuinely
   asymmetric and rule 3 produces an obviously-wrong direction,
   add a higher-priority rule before rule 3 — never below.

   **Example mixed-signal pair** (for the reasoning prompt):
   suppose ENG-100 renames `lib/foo.sh` → `lib/internal/foo.sh`
   and ENG-200 introduces a new function `_foo_helper` in the
   same file's old path. Rule 1 fires for ENG-100 (renamer side);
   rule 2 fires for ENG-200 (interface-introducer side); they
   point in opposite directions. Rule 3 takes over (mixed
   conflicting evidence is one of its enumerated subclasses):
   smaller suffix wins → ENG-100 is parent, ENG-200 is child.
   Rationale: `Both restructure lib/foo.sh: ENG-100 renames the
   file, ENG-200 adds _foo_helper. Heuristics conflict;
   numeric-suffix tiebreaker (100 < 200).`
4. **One candidate per pair, even with multiple overlaps.** If A
   and B share a path AND a referenced identifier AND a rename, the
   proposed edge is **one** `blocked-by` relation with a multi-fact
   rationale. The `coord-dep-audit` JSON block only stores parent
   IDs, so granularity finer than "one edge per pair" buys nothing
   for cleanup at `/close-issue`.
5. **Output:** array of `{child, parent, category, rationale}`
   tuples. Category is one of `path-collide` / `identifier` /
   `rename` (or comma-joined when multi-fact).

The reasoning is held in skill prose, not codified in a script. Per
ENG-280: "A script can flag that two specs reference the same path;
only reasoning can judge whether the edits are in disjoint sections
(safe to run in parallel) or logically coupled."

### 4. Step 2 sub-step 5 — per-candidate operator gate

Skill prose presents candidates one at a time. Per candidate:

```
Candidate edge: ENG-A → blocked-by ENG-B  (path-collide)
  Rationale: Both restructure `lib/scope.sh::_scope_load` —
             ENG-B introduces the function, ENG-A renames it.

  [accept / reject / abort]?
```

* **accept** — append to `accepted_edges`, move to next.
* **reject** — drop the candidate, move to next. Operator can
  always add the relation manually via Linear UI later; the next
  `/sr-start` will see it in `existing_blockers` and not re-prompt.
* **abort** — stop the gate immediately. No Linear writes have
  happened yet (writes are sub-step 6, after the gate completes).
  Exit Step 2 with stderr `step 2: scan aborted by operator —
  dispatch halted`. Do NOT proceed to Step 3.

**No `edit-rationale` option.** ENG-280 has it because finalize
will commit the rationale to a Linear comment in the same atomic
transaction; operators want to fix wording before commit. ENG-281's
audit comment is composed by skill prose at write time (sub-step 6),
and the operator can edit the posted comment via Linear UI after
the fact. Adding edit-rationale here would duplicate that fix-up
window with no additional safety.

**No `flip-direction` option (v1 limitation).** When the heuristic
proposes a direction the operator disagrees with, they reject and
add the correct direction by hand via Linear UI before the next
`/sr-start`. The next scan won't re-prompt because the manually-
added relation is now in `existing_blockers`. Adding flip would
be a fourth gate option; preserve UX symmetry with ENG-280's
three-choice gate (accept/reject/edit-rationale ↔
accept/reject/abort) for now and revisit if it bites in practice.
See **Known limitations (v1)**.

### 5. Step 2 sub-step 6 — per-child write loop (relations, comment, label)

Run after the gate completes with non-empty `accepted_edges`. Group
edges by child; iterate per child. The per-child sequence mirrors
ENG-280 step 12 sub-steps 4–7 (relations BEFORE comment, comment-
LAST, label after comment) so cleanup-time semantics are identical.

`accepted_edges_json` is a JSON array of
`{child, parent, rationale}` objects in conversation context after
the gate. Iterate via jq; bash arrays cannot model nested-record
access, so the implementer indexes into the JSON directly:

```bash
# Children to process, in numeric-suffix order so failures land on
# deterministic children across re-runs.
children=$(printf '%s' "$accepted_edges_json" \
  | jq -r '[.[].child] | unique
           | sort_by(. | sub("^[A-Z]+-"; "") | tonumber) | .[]')

for child in $children; do
  # All edges accepted for this child (preserves rationale order
  # the operator saw at gate time).
  child_edges_json=$(printf '%s' "$accepted_edges_json" \
    | jq --arg c "$child" '[.[] | select(.child == $c)]')

  INITIAL_BLOCKERS=$(linear_get_issue_blockers "$child" \
    | jq -r '.[].id' | sort -u)

  # newly_added_parents — parents this run actually creates via
  # linear issue relation add. The audit comment lists only this
  # set; cleanup at /close-issue treats only this set as
  # delete-authority. Pre-existing parents (already in
  # INITIAL_BLOCKERS) are NEVER added here — Step 2 cannot
  # distinguish "operator added this manually for a coord-dep
  # reason" from "operator added this for a semantic reason that
  # happens to align with our scan," so claiming audit-trail
  # authority over them would risk over-claiming cleanup
  # authority for legitimately-semantic relations.
  newly_added_parents=()
  edge_count=$(printf '%s' "$child_edges_json" | jq 'length')
  for (( i = 0; i < edge_count; i++ )); do
    parent=$(printf '%s' "$child_edges_json" | jq -r ".[$i].parent")

    # Pre-existing parent (operator added it manually between
    # scan and write loop, OR an earlier-iteration of the gate
    # already accepted and committed it). Skip the relation-add
    # call — no audit-set membership. The operator's manual edge
    # keeps whatever classification they gave it (semantic,
    # prior coord-dep, etc.); Step 2 does NOT overwrite that.
    # Log a WARN line naming the pair so the operator sees the
    # race occurred — useful for diagnosing why /close-issue's
    # cleanup later doesn't auto-remove this relation.
    if printf '%s\n' "$INITIAL_BLOCKERS" | grep -qx "$parent"; then
      echo "step 2: WARN — accepted edge $child blocked-by $parent was added concurrently (pre-existing in INITIAL_BLOCKERS); Step 2 will not claim audit authority over it. The relation stays as-is in Linear with whatever classification the operator gave it." >&2
      continue
    fi

    if linear issue relation add "$child" blocked-by "$parent"; then
      newly_added_parents+=("$parent")
    else
      # Per-edge failure: retry / skip-this-edge / abort.
      # See "Per-edge failure choices" below for semantics.
      :
    fi
  done

  # No newly-added parents → nothing to audit (operator's manual
  # adds keep their existing classification); skip comment + label.
  [[ "${#newly_added_parents[@]}" -eq 0 ]] && continue

  # Compose audit comment per ENG-280's contract.
  # Bullets and JSON parents array both list newly_added_parents
  # (the parents this run actually created via relation add).
  # Pre-existing parents are deliberately excluded — see the
  # comment on the loop above.
  body_file=$(mktemp)
  {
    printf '%s\n\n' "**Coordination dependencies added by /sr-start scan**"
    for (( i = 0; i < edge_count; i++ )); do
      parent=$(printf '%s' "$child_edges_json" | jq -r ".[$i].parent")
      rationale=$(printf '%s' "$child_edges_json" | jq -r ".[$i].rationale")
      printf '%s\n' "${newly_added_parents[@]}" | grep -qx "$parent" || continue
      printf -- '- blocked-by %s — %s\n' "$parent" "$rationale"
    done
    parents_json=$(printf '%s\n' "${newly_added_parents[@]}" \
      | jq -R . | jq -sc '{parents: .}')
    printf '\n```coord-dep-audit\n%s\n```\n\n' "$parents_json"
    printf '%s\n' "Will be removed automatically on \`/close-issue\`."
  } > "$body_file"

  if ! linear issue comment add "$child" --body-file "$body_file"; then
    rm -f "$body_file"
    # Per-comment failure: retry / rollback.
    # Rollback iterates newly_added_parents (the only relations
    # this run created); pre-existing relations are never touched.
    :
  fi
  rm -f "$body_file"

  # Label add — log-and-continue (label is observational).
  linear_add_label "$child" "$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL" \
    || echo "step 2: failed to add coord-dep label to $child — continuing" >&2

  # Per-child verify (sub-step 7).
  # EXPECTED is INITIAL_BLOCKERS plus newly_added_parents — what
  # we expect Linear to look like after this run's writes.
  EXPECTED=$(printf '%s\n' "$INITIAL_BLOCKERS" "${newly_added_parents[@]}" \
    | sort -u)
  ACTUAL=$(linear_get_issue_blockers "$child" \
    | jq -r '.[].id' | sort -u)
  if [[ "$EXPECTED" != "$ACTUAL" ]]; then
    echo "step 2: blocker-set mismatch on $child" >&2
    echo "  expected: $EXPECTED" >&2
    echo "  actual:   $ACTUAL" >&2
    echo "step 2: aborting before Step 3 — investigate manually" >&2
    # Persist verify_drift entry per the recovery-file schema
    # (Component 2). The drift record's newly_added_parents
    # field is exactly the variable above; expected_blockers
    # and actual_blockers are the two sets compared.
    return 1   # surfaces as Step 2 abort in skill prose
  fi
done
```

The `: # see ... below` placeholders in the bash sketch are where
the per-edge and per-comment failure-handling branches plug in;
the failure-choice prose immediately following expands them
inline. This keeps the algorithm sketch readable (one screenful)
without duplicating the branch logic in two places.

**Per-edge failure choices** (when `linear issue relation add`
fails — applies only to parents not already in
`INITIAL_BLOCKERS`; pre-existing parents skip the relation-add
call entirely and never reach this branch):

* **retry** — re-attempt the same parent.
* **skip-this-edge** — drop this parent from `newly_added_parents`
  (it was never appended in the first place since the relation-add
  failed). The audit comment will not list it. Operator can re-add
  manually via Linear UI; next `/sr-start` will see it in
  `existing_blockers` and skip it silently. Unlike ENG-280, all
  skipped edges are coord-dep (not PREREQS), so skip-this-edge is
  always safe here.
* **abort** — stop the loop. Children processed before the failure
  are fully audited (their comments + labels landed). The current
  child has partial relations without an audit comment.
  **Before exiting**, append each `(child, parent, rationale)`
  triple from `newly_added_parents` for the current child to
  `<repo>/.sensible-ralph/coord-dep-recovery.json`'s `orphans`
  array. The next `/sr-start` reads the file at sub-step 1 and
  attempts repair (compose-and-post the audit comment from the
  persisted rationale).

  Surface the manual recovery recipe inline so the operator knows
  what state Linear is in right now:
  ```
  linear issue relation delete <child> blocked-by <parent>
  ```
  for each entry in `newly_added_parents` so far on the current
  child. The persisted recovery file is the durable signal; the
  inline recipe is just for the operator's situational awareness.
  Do NOT proceed to Step 3.

**Per-comment failure choices** (when `linear issue comment add`
fails after relations were added):

* **retry** — usually transient.
* **rollback** — best-effort
  `linear issue relation delete "$child" blocked-by "$parent"`
  for each entry in `newly_added_parents`. By construction
  (see the loop above) `newly_added_parents` contains only
  relations Step 2 actually created via `linear issue relation
  add` — pre-existing operator-set blockers were never added
  here and cannot appear in the rollback sweep.

  **Re-fetch blockers** after the delete sweep; for each parent
  in `newly_added_parents` still present (delete failed for any
  reason), append the `(child, parent, rationale)` triple to
  `<repo>/.sensible-ralph/coord-dep-recovery.json`'s `orphans`
  array so the next `/sr-start` can repair. Do NOT add label;
  do NOT proceed to Step 3.

**No `proceed-anyway` option.** ENG-280's analogous failure point
offers proceed-anyway because ENG-280 keeps the issue in
`In Design` with the transport file intact, so the next
`/sr-spec` reloads and retries the comment-post — the orphan
window is bounded by the next re-run. ENG-281's resume mechanism
is the **durable recovery file** (`<repo>/.sensible-ralph/coord-
dep-recovery.json`, see sub-step 1), but introducing
`proceed-anyway` on top of recovery would only complicate the
contract: the operator would have a manual-post step they might
forget, separate from the auto-repair the next `/sr-start`
already attempts. The retry path covers the typical transient-
API-error case; rollback (with recovery-file fallback for
delete failures) is the clean exit for unrecoverable comment
failures. The recovery file makes orphan handling auto-repairing
across runs.

**Label-add failure** is log-and-continue — the comment is the
load-bearing artifact for cleanup, not the label. The label is
observational (filter discoverability in Linear UI).

### 6. Step 2 sub-step 7 — per-child verification

Inline at the end of each child's iteration in sub-step 6 (see
shell sketch above). On any mismatch, exit Step 2 non-zero and do
NOT proceed to Step 3.

**`EXPECTED == ACTUAL` exact-set check** carries the same known
limitation ENG-280 surfaces: a concurrent semantic-blocker add by
a human between `INITIAL_BLOCKERS` capture and the post-add re-fetch
makes `ACTUAL ⊃ EXPECTED` and currently aborts. Mitigation: rare;
operator can re-run `/sr-start` and the scan fast-paths through.
Future fix: change verify to "every required parent is present"
(subset, not equality), shared with ENG-280's verify.

**On verify failure: persist a `verify_drift` record** to the
recovery file before aborting Step 2. Verify only runs after all
sub-step 6 writes (relations, comment, label) succeeded, so the
audit trail for `committed_parents` is intact and orphans aren't
possible — but operators benefit from a durable record that
distinguishes "this child's run aborted at verify with these
blockers" from "this child's run completed cleanly." The shape
is the `verify_drift` array in the recovery file's schema. The
next `/sr-start`'s sub-step 1 surfaces drift entries to the
operator (informational; no auto-repair, since nothing is
broken), and the operator can manually clear the record after
investigating:

```bash
# After investigating, operator removes drift entries via:
jq '.verify_drift = []' "$RECOVERY_FILE" \
  | tee "$RECOVERY_FILE.tmp" >/dev/null \
  && mv "$RECOVERY_FILE.tmp" "$RECOVERY_FILE"
```

Drift entries do NOT block subsequent dispatch; they are
observability records only.

### 7. SKILL.md surface changes

`skills/sr-start/SKILL.md` updates:

1. **Step renumber.** Today's Steps 2/3/4 become Steps 3/4/5. New
   Step 2 documents the scan per Components 1–6 above. The SKILL.md
   step-count is the only number that bumps; in-prose references to
   "Step N" in other files (none exist outside SKILL.md as of the
   spec base SHA) follow if any are added later.
2. **Section "Workflow (run in order)"** gains the new Step 2
   between today's Step 1 and Step 2. The new section header is
   `### Step 2: Coordination-dependency backstop scan`.
3. **Section "Red flags / when to stop"** gains a new bullet:
   `**Coord-dep scan aborted:** do NOT dispatch. The aborted scan
   has either left no Linear writes (gate-time abort) or surfaced
   a write-loop failure with a recovery recipe; resolve before
   re-running /sr-start.`

No changes to `preflight_scan.sh`, `build_queue.sh`,
`orchestrator.sh`, `dag_base.sh`, or `toposort.sh`.

### 8. Living-doc update

`docs/design/preflight-and-pickup.md` documents the existing
preflight set (Canceled blocker, Duplicate blocker, deep-stuck
chain, missing PRD, out-of-scope blocker, missing workspace label)
under "Preflight anomaly set" and explicitly distinguishes the
pickup rule from the preflight scan in its opening paragraphs.
ENG-281 adds a new gate that is **neither** a pickup-rule check
nor a preflight anomaly: it's a reasoning-driven step between the
two with its own operator-interaction model.

Update `docs/design/preflight-and-pickup.md` in the same commit as
the SKILL.md change to add a new top-level section
`## Coordination-dependency scan` after `## Preflight anomaly set`
and before `## Pre-existing blocker vs. in-run queue: the non-
obvious case`. Section content (in living-doc voice — describes
how the system works *now*, post-merge):

* What the scan does (one paragraph).
* Where it fits in the flow (one paragraph; reference SKILL.md's
  Step 2 by name).
* Relationship to ENG-280's primary scan (one paragraph; this is
  the backstop).
* Pointer to `/close-issue`'s cleanup helper (cross-link to
  `linear-lifecycle.md` and `skills/close-issue/SKILL.md` step 8).

Treat this as part of the unit-of-work rule (CLAUDE.md): code +
SKILL.md prose + design doc land in one commit/PR.

## Edge cases

* **0 Approved peers in scope.** Helper emits `{"approved": []}`;
  Step 2 sub-step 3 fast-paths to "No coordination dependencies
  detected" and proceeds to Step 3.
* **1 Approved peer.** Same fast path — no pairs possible.
* **N Approved peers, every pair already covered.** Helper emits
  full bundle; sub-step 4 candidate filter leaves the candidate
  list empty; sub-step 3 fast-path emits the same one-line summary and
  proceeds.
* **A peer's description is structurally thin** (200+ chars but
  no concrete file-touch information — e.g., headings only, vague
  prose). Step 1's PRD check has already passed by definition;
  Step 2 cannot enrich. **Per-peer operator gate (do NOT halt the
  whole queue on one weak peer):** when the reasoning step
  cannot determine the file-touch surface for a peer with
  enough confidence to rule out overlap with another Approved
  peer, surface the per-peer choice:

  ```
  step 2: ENG-A description is too thin to scan reliably for
  coord-dep with [ENG-B, ENG-C, ...]. Pairs involving ENG-A
  cannot be classified.

  Choose:
  (a) accept-risk — treat ENG-A's pairs as no-overlap, proceed
      with the rest of the scan and dispatch the queue. The
      backstop's safety guarantee is suspended for ENG-A's
      pairs only.
  (b) abort — stop /sr-start. Operator amends ENG-A via /sr-spec
      (add concrete file-touch detail) or removes ENG-A from
      the Approved set (move to In Design / cancel) before
      re-running.
  ```

  This is a per-peer prompt, not a global halt. Choosing (a)
  excludes ENG-A's pairs from candidate consideration for this
  run AND surfaces a stderr summary at end of Step 2: `step 2:
  ENG-A's pairs were skipped due to thin description (operator
  accepted risk).` The skill does NOT auto-mutate ENG-A in
  Linear; the operator's risk-acceptance is a runtime decision,
  not a state change. Pairs that don't involve thin peers
  proceed normally — one weak peer cannot block dispatch of
  unrelated Approved issues.

  Choosing (b) is the fail-closed path. Use when ENG-A's
  potential overlaps are high-stakes (touches well-known shared
  surface like `lib/scope.sh`) and the operator wants to triage
  before dispatch.

  Future fix: tighten Step 1's `_desc_nonws_chars` heuristic to
  better correlate with reasoning-readiness, but the threshold
  is hard to characterize prescriptively.
* **Linear API failure mid-helper.** Helper exits 1, stderr names
  the offending issue. Operator chooses: retry, skip Step 2
  (proceed to Step 3 — ENG-280 covered most edges already at
  `/sr-spec` time), or abort.
* **Operator declared a `blocked-by` manually between scan and
  write loop.** New blocker shows up in `INITIAL_BLOCKERS` for
  that child. The relation-add for the same parent is skipped
  (it's already there); the audit comment includes the parent in
  its `parents` array; the verify check passes. Effectively the
  scan retroactively audits the manual edge. Acceptable.
* **Operator removed an audit comment via Linear UI between scan
  and write loop.** Audit comment for the affected child is
  re-posted. Cleanup at `/close-issue` walks ALL audit comments
  per ENG-280's algorithm, so duplicates do not break cleanup; the
  union of parent IDs is taken.
* **Re-spec mid-Approved-set (an issue's spec changes between two
  `/sr-start` runs).** Re-spec via `/sr-spec` triggers ENG-280's
  scan and writes any new edges. Pre-existing audit edges from
  this issue's prior coord-dep audits stay; new edges from
  re-spec are added; unrelated coord-dep audits on OTHER children
  blocking this issue stay in place. Backstop scan on the next
  `/sr-start` finds all existing edges in `existing_blockers` and
  fast-paths through. Acceptable.
* **Issue exits the Approved set between scan and write loop**
  (operator cancels it via Linear UI, or `ralph-failed` is
  applied). The peer is no longer in the helper's bundle on the
  NEXT scan, but the current run already captured it. If the
  exited peer is the parent of an accepted edge: the
  `linear issue relation add` succeeds (Linear allows blocked-by
  on Canceled issues; preflight_scan.sh would flag it on the next
  run as a Canceled-blocker anomaly). If the exited peer is the
  child: same — relation lands. Both are correct in the sense
  that the operator gets a Step 1 anomaly on the next run that
  forces them to address the now-broken sequence.

## Testing

`skills/sr-start/scripts/test/coord_dep_backstop_scan.bats` —
bats coverage for the data-assembly helper. The reasoning step
itself is NOT unit-tested (Claude prose, codex-reviewed at spec
time per ENG-280's pattern).

Asserts:

* Empty Approved set → emits `{"approved": []}`, exit 0.
* Single Approved peer → emits singleton array with that peer's
  data, exit 0.
* Multiple peers → emits all peers; descriptions verbatim;
  `existing_blockers` populated from `linear_get_issue_blockers`.
* A peer's description is empty → empty string in JSON, valid JSON
  preserved.
* `linear_list_approved_issues` failure → exit 1, stderr
  diagnostic.
* Per-peer `linear issue view` failure → exit 1, stderr names the
  offending peer.
* Per-peer `linear_get_issue_blockers` failure → exit 1, stderr
  names the offending peer.
* `existing_blockers` includes parents in any state (Approved,
  Done, Canceled, Duplicate, Backlog, Todo, In Progress, In
  Review). Mock fixtures cover at least Approved + Done +
  Canceled.
* Self-referential edge case: a peer with itself in
  `existing_blockers` (impossible in Linear by construction but
  defensively tested) is preserved as-is — the skill prose's
  candidate-pair filter excludes self-pairs.

`lib/test/` does NOT need new bats files; ENG-280 ships
`linear_remove_label.bats` and the `coord-dep-audit` cleanup tests
already cover the multi-comment-per-child case ENG-281 introduces
(per the ENG-280 spec's testing section: "Multi-comment dedup
(same parent in fenced blocks across multiple comments collapses
to one delete)").

**Recovery-file behavior** is exercised via end-to-end manual
testing rather than bats — the read-and-repair flow is skill
prose (no script to invoke standalone), and the failure modes it
handles (per-edge abort, per-comment partial-rollback, verify
failure) require mocked Linear responses that bats wouldn't
reach. Test scenarios to walk through manually before merge:

* No recovery file present → sub-step 1 is a no-op, scan proceeds
  normally.
* Recovery file with one orphan triple → sub-step 1 attempts
  audit-comment post; on success, file is deleted; scan proceeds.
* Recovery file with multiple orphans for the same child →
  sub-step 1 composes one consolidated audit comment per child;
  on success, all of that child's entries are removed.
* Recovery file with malformed JSON (operator hand-edited badly)
  → sub-step 1 refuses to auto-delete; surfaces both manual-
  repair options (hand-fix JSON, or rebuild orphan list from
  Linear); operator must consciously address before re-running.
* Recovery-attempt failure (Linear API down) → entries kept;
  warning surfaced; scan proceeds with sub-step 2 normally.
* Per-edge abort writes recovery entries before exit; verify
  next `/sr-start` reads them and repairs.
* Per-comment rollback with one delete-failure writes one
  recovery entry; verify repair on next run.
* Verify failure on a child writes a `verify_drift` entry; next
  `/sr-start` surfaces the entry as informational output and
  does NOT auto-repair (audit trail is intact for committed
  parents).
* Atomic-write contract: simulate a process kill between the
  temp-file write and rename; verify the recovery file is
  either fully untouched (rename never happened) or fully
  updated (rename completed) — never half-written. This is the
  invariant the temp+rename pattern guarantees.
* Mixed file state: `orphans` non-empty AND `verify_drift`
  non-empty → sub-step 1 repairs orphans; surfaces drift; both
  paths complete in one run.

End-to-end testing is manual: dispatch a `/sr-start` against an
Approved set with a known overlap, accept the candidate, verify
the relation lands, the audit comment is posted with the correct
`coord-dep-audit` JSON block, the label is added, and the next
`/sr-start` does not re-prompt the audited pair.

## Prerequisites

* **Blocked-by ENG-280** (Approved as of `5d46269`). ENG-280 ships
  the shared infrastructure ENG-281 reuses verbatim:
  * `coord_dep_label` plugin option (default `ralph-coord-dep`)
    and its mirror in `lib/defaults.sh`.
  * `lib/linear.sh::linear_remove_label` helper (used at cleanup
    time, not by ENG-281's scan but required by the contract).
  * `coord-dep-audit` audit-comment fenced-block format.
  * `ralph-coord-dep` workspace-label preflight wired into
    `preflight_labels_check`.
  * `skills/close-issue/scripts/cleanup_coord_dep.sh` — handles
    cleanup for both producers; per ENG-280's "Out of scope":
    "ENG-281 reuses the same marker, label, and `/close-issue`
    cleanup; no further `/close-issue` change is needed when
    ENG-281 lands."

**Spec base SHA vs. implementation baseline.** The spec base SHA
named in this document's header (`5d4626…`) captures the state of
`main` at `/sr-spec` time; ENG-280's artifacts are NOT yet on `main`
at that SHA (ENG-280 is Approved, not Done, and its spec lives on
its own branch). That is by design under the per-issue branch
lifecycle (ENG-279, see `docs/design/worktree-contract.md`): when
the orchestrator dispatches ENG-281, `dag_base.sh` resolves the
in-review parent (ENG-280) and `worktree_create_with_integration`
merges ENG-280's branch into ENG-281's worktree before
`claude -p` is invoked, so ENG-280's artifacts are present at the
implementation baseline by construction. The spec is written
assuming that merged baseline. An implementer running this issue
manually (without `/sr-start`) must merge ENG-280's branch first,
or wait for ENG-280 to land on `main`.

No other dependencies. `/sr-start`'s existing flow
(`preflight_scan.sh`, `build_queue.sh`, `orchestrator.sh`,
`dag_base.sh`, `toposort.sh`) is untouched.

## Out of scope

* `flip-direction` operator option in the per-candidate gate.
  Deferred to v2; see **Known limitations (v1)**.
* `edit-rationale` operator option. Operator can edit the posted
  comment via Linear UI after the fact.
* Mechanical pre-filter (regex-based path/identifier extraction)
  before reasoning. The scan stays reasoning-driven; pre-filter
  is a future optimization once the cost regime is observed in
  practice with larger Approved sets.
* Caching of prior-scan results across `/sr-start` invocations.
  Re-scan is cheap when filtered candidate sets are small (most
  pairs are covered by `existing_blockers` after the first
  acceptance).
* Migration tooling for issues already in `In Review` or `Done`
  before this lands. The backstop only operates on the Approved
  set; in-review/done issues are out of its remit.
* Symmetric notification on the parent issue (a "you blocked this
  child" comment on the parent). Single-side audit on the child
  matches ENG-280; symmetric notification adds Linear write
  surface for marginal forensics value.
* Storing relation IDs (returned by `linear issue relation add`)
  in the audit JSON for per-instance cleanup. Same v2 future as
  ENG-280's analogous limitation.

## Known limitations (v1)

Surfaced now and explicitly accepted as v1 trade-offs.

* **No `flip-direction` operator option.** When the heuristic
  proposes a `(child, parent)` direction the operator disagrees
  with, the operator must reject the candidate and add the
  inverse relation manually via Linear UI before the next
  `/sr-start`. Symmetric collisions and mixed-signal pairs (where
  the numeric-suffix tiebreaker resolves direction) hit this
  most often. Mitigation: the rationale text on a tiebreaker-
  resolved direction says so explicitly; the operator sees the
  choice was a tiebreak. Future fix: add `flip-direction` as a
  fourth gate option.
* **Auto-repair-vs-immediate-cleanup gap on per-edge abort.**
  Per-edge `abort` exits the loop with the current child holding
  partial audit-less relations. Sub-step 6's abort path writes
  these to `coord-dep-recovery.json`, and sub-step 1 of the next
  `/sr-start` attempts auto-repair (compose-and-post the audit
  comment from persisted rationales). The gap: between the abort
  and the next `/sr-start` invocation, the orphan relations exist
  in Linear without an audit comment. If `/close-issue` runs in
  that window (extremely unlikely — `/close-issue` requires
  `In Review`, and a coord-dep child entering review without the
  audit comment posted means an even more anomalous flow), the
  cleanup helper won't find the orphan and won't remove it.
  Mitigation: in practice `/close-issue` on a child that just
  had a coord-dep abort is days or weeks away (the child needs
  to dispatch, complete, review). Recovery file repairs first.
  Future fix: have `/sr-start` sub-step 1's auto-repair also
  surface a Linear-UI link to the orphan relations so the
  operator can act sooner if needed.
* **`EXPECTED == ACTUAL` exact-set verify treats benign
  concurrent UI adds as drift.** Same limitation ENG-280 surfaces.
  Mitigation: rare; operator re-runs and the scan fast-paths
  through. Future fix: change verify to subset semantics, shared
  with ENG-280's verify.
* **Description-vs-worktree drift.** The scan reads peer
  descriptions, not branch worktree contents. If `/sr-spec`'s
  finalize sub-step 5 fails to push the description (network
  hiccup, partial write) but the spec file landed on the branch
  before the abort, the description and worktree diverge until
  the operator fixes it. The scan reasons over the description,
  potentially missing overlaps. Mitigation: ENG-280's finalize
  is all-or-nothing-before-Approved, so a partial description
  push leaves the issue in `In Design` (not Approved) and the
  scan never sees it. Future fix: switch both ENG-280 and
  ENG-281 to worktree source if drift is observed.
* **Concurrent-add race during operator gate.** If between
  scan-time (sub-step 2's helper invocation) and write-time
  (sub-step 6's `linear issue relation add`) someone — the
  operator themselves, a teammate, or another tool — adds the
  same `blocked-by` relation that the gate accepted, sub-step 6
  detects the parent already in `INITIAL_BLOCKERS` and skips
  the relation-add. The accepted edge does NOT make it into the
  audit comment, does NOT become an orphan, and does NOT get
  the `ralph-coord-dep` label authority. The relation stays in
  Linear as the operator's manual edge — keeping whatever
  classification the operator gave it (semantic, prior coord-
  dep, anything else). `/close-issue` cleanup won't auto-
  delete it; the operator can manually delete it if they want.
  Step 2 emits a stderr WARN line at write time naming the
  affected pair so the race is observable. Mitigation: rare;
  the operator gate window is seconds-to-minutes. Future fix:
  extend ENG-280's `coord-dep-audit` JSON shape with a
  `newly_added_parents` field so cleanup can distinguish
  Step 2-claimed authority from operator-manual relations
  carried in the audit comment for observability — would
  require coordinated change to `cleanup_coord_dep.sh`.
* **Audit-comment UI deletion after Step 2 exit produces orphan
  relations.** If the operator deletes a `coord-dep-audit`
  comment via Linear UI later (between Step 2 exit and
  `/close-issue`), the relation persists but cleanup at
  `/close-issue` cannot find it (cleanup walks audit blocks per
  ENG-280's helper; absent comment ⇒ absent block ⇒ no delete
  authority). The next `/sr-start` sees the relation in
  `existing_blockers` and fast-paths the pair, leaving no
  trigger to re-audit. This is a **shared limitation with
  ENG-280's cleanup model** — both producers' relations are
  vulnerable to the same UI-deletion path. Mitigation: don't
  delete `coord-dep-audit` comments via UI; remove the relation
  itself if the dependency no longer applies. Future fix: store
  Linear's relation IDs in audit JSON (the same per-instance-
  cleanup direction ENG-280 already names as future work).

## Acceptance criteria

1. `skills/sr-start/scripts/coord_dep_backstop_scan.sh` exists,
   takes no positional args, reads env vars
   `$SENSIBLE_RALPH_PROJECTS`,
   `$CLAUDE_PLUGIN_OPTION_APPROVED_STATE`,
   `$CLAUDE_PLUGIN_OPTION_FAILED_LABEL`, and emits the documented
   JSON bundle on stdout. Exits 0 on empty/singleton Approved
   sets; exits 1 on Linear CLI failure with stderr naming the
   offending issue.
2. `skills/sr-start/SKILL.md` documents a new Step 2 between
   today's Step 1 (preflight) and today's Step 2 (build_queue).
   Today's Steps 2/3/4 are renumbered to 3/4/5. New Step 2
   covers (in order): orphan-recovery from
   `<repo>/.sensible-ralph/coord-dep-recovery.json`, helper
   invocation, fast paths (0/1 peer, all-pairs-covered),
   reasoning checklist, per-candidate operator gate, per-child
   write loop, per-child verification.
3. New Step 2's reasoning prompt structure is documented inline
   in SKILL.md, including the **seven-item checklist** (path,
   identifier, rename, plus an open-ended item for any other
   sequencing dependency or shared invariant) and the
   deterministic three-rule direction heuristic (rename-before-
   edit one-sided → interface-before-use one-sided → numeric-
   suffix tiebreaker as unconditional final fallback).
4. The audit comment Step 2 posts uses the `coord-dep-audit`
   fenced-block JSON format defined in ENG-280's spec, verbatim.
   The header text reads `**Coordination dependencies added by
   /sr-start scan**` (vs. ENG-280's `/sr-spec`).
5. The label Step 2 adds is `$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL`,
   applied to each child that received at least one accepted edge,
   via `linear_add_label`.
6. Per-edge failure handling (retry / skip-this-edge / abort)
   matches ENG-280 step 12 sub-step 4 semantics exactly. Per-
   comment failure handling is **retry / rollback only** — no
   `proceed-anyway` option (rationale: see Component 5; ENG-281
   has no resume-on-rerun mechanism). Label-add failure is
   log-and-continue.
7. Per-child verification: `EXPECTED == ACTUAL` over
   `INITIAL_BLOCKERS ∪ committed_parents`. On mismatch, abort
   Step 2 with diagnostic; do NOT proceed to Step 3.
7a. Recovery file `<repo>/.sensible-ralph/coord-dep-recovery.json`
    holds two arrays: `orphans` (audit-less relations Step 2
    created) and `verify_drift` (relations whose verify check
    disagreed with Linear's reported blockers). Writes use
    temp-file + rename for atomicity. The `orphans` array
    contains ONLY parents from `newly_added_parents` — pre-
    existing parents are never claimed as Step 2 authority.
    Per-edge `abort` writes orphan triples for the current
    child; per-comment rollback delete-failure writes triples
    for any newly-added parent whose delete returned non-zero.
    The `verify_drift` array is populated on sub-step 7 verify
    failure with `{child, newly_added_parents,
    expected_blockers, actual_blockers, audit_comment_posted,
    label_added, drifted_at}`. Sub-step 1 of the next
    `/sr-start` reads both arrays: orphans get auto-repair
    (compose-and-post audit comment, prune on success); drift
    entries are surfaced to the operator as informational
    output (no auto-action). Malformed file MUST be hand-
    repaired or rebuilt by the operator — auto-deletion is NOT
    offered. Schema is documented in Component 2.

    **Critical invariant:** Step 2 only ever claims audit
    authority over relations it directly created via
    `linear issue relation add`. Pre-existing parents (already
    in `INITIAL_BLOCKERS` at write time) keep whatever
    classification the operator gave them — semantic, prior
    coord-dep, or anything else. Step 2 does not list them in
    audit comments, does not include them in `orphans`, and
    does not delete them on rollback. This avoids over-claiming
    cleanup authority over legitimately-semantic edges.
8. New bats file `skills/sr-start/scripts/test/coord_dep_backstop_scan.bats`
   covers the helper's data-assembly contract per the **Testing**
   section. Existing bats coverage for `lib/linear.sh`,
   `lib/preflight_labels.sh`, `skills/sr-start/scripts/`, and
   affected skills continues to pass.
9. `docs/design/preflight-and-pickup.md` gains a new
   `## Coordination-dependency scan` section per Component 8
   above, landed in the same commit/PR as the code change.
10. End-to-end (manual): `/sr-start` on an Approved set with a
    known overlap surfaces the candidate, applies the accepted
    edge via `linear issue relation add`, posts the
    `coord-dep-audit` comment, adds the `ralph-coord-dep` label,
    and proceeds to Step 3. A subsequent `/sr-start` does not
    re-prompt the audited pair.
11. **One-off post-`/close-issue` for THIS issue:** rename
    ENG-281's Linear title from "Add hidden-dependency backstop
    scan to /sr-start preflight" to "Add coord-dep backstop scan
    to /sr-start preflight" via `linear issue update ENG-281
    --title "..."` AFTER worktree teardown (Linear's auto-
    recomputed `.branchName` no longer matters then). Mirrors
    ENG-280's analogous one-off rename in its own acceptance
    criteria.
