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
                ├─ if committed coord-dep edges non-empty: post audit comment LAST
                │     (with structured ```coord-dep-audit block as cleanup authority)
                ├─ if committed coord-dep edges non-empty: linear_add_label (coord-dep)
                ├─ verify ACTUAL == INITIAL_BLOCKERS ∪ PREREQS ∪ committed_parents
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
consolidated audit comment with two parts: a human-readable bullet
list and a **structured machine-readable JSON block**. Cleanup
parses ONLY the structured block — never the bullet text or any
other free-form comment content.

Comment format:

````
**Coordination dependencies added by /sr-spec scan**

- blocked-by ENG-X — both restructure `lib/scope.sh`'s `_scope_load` function
- blocked-by ENG-Y — ENG-Y renames `foo.sh` which this spec edits inline

```coord-dep-audit
{"parents": ["ENG-X", "ENG-Y"]}
```

Will be removed automatically on `/close-issue`.
````

Two distinct contracts:

- **Bullet lines** — human-readable rationale for operator review.
  Consumed by humans only. Not parsed by any tool.
- **Fenced block with the language tag `coord-dep-audit`** — the
  cleanup-authoritative source. Cleanup uses awk/jq to extract
  exactly these blocks and reads `parents` from each. This is the
  ONLY way for a comment to instruct cleanup to delete relations.

**Why a fenced JSON block (not free-form regex):**

- The fence language tag `coord-dep-audit` is unusual enough that
  prose accidentally typing it in a fenced block is implausible.
- Cleanup ignores everything outside the structured block —
  arbitrary comment content (operator notes, quoted examples,
  even the bullet lines we ourselves write for human readability)
  cannot become delete authority.
- Forward-compatible: the JSON object can grow new keys (e.g., a
  `run_id` or per-edge metadata) without breaking older cleanup
  parsers.

The cleanup extraction in `cleanup_coord_dep.sh`:

```bash
# Extract content between ```coord-dep-audit ... ``` fences across
# all matching comment bodies. awk handles the multi-line pattern;
# jq slurps each block and unions parents.
parents=$(printf '%s' "$comments" | jq -r '.data.issue.comments.nodes[].body' \
  | awk '/^```coord-dep-audit$/{flag=1; next} /^```$/{if(flag){print ""}; flag=0} flag' \
  | jq -rs '[.[] | (.parents // [])] | flatten | unique | .[]?' 2>/dev/null \
  | sort -u)
```

The `awk` extracts only blocks fenced by ` ```coord-dep-audit ` and
its matching ` ``` ` close. The `jq -rs` slurps all blocks as JSON
documents, unions their `parents` arrays, dedups, prints one
parent ID per line. If no blocks match or any block is malformed,
the pipeline produces an empty `parents` (the cleanup's
no-marker fast path then runs).

**Residual limitation, documented:** if an operator manually
removes a coord-dep relation and then later re-adds the same
parent ID as a SEMANTIC `blocked-by`, cleanup will still delete
that semantic relation when the issue closes (the JSON block
records the parent ID, not the specific relation instance).
Workaround: removing the marker entry from the audit comment by
hand before closing. Provenance at the relation-instance level
(e.g., comparing relation `createdAt` timestamps) was considered
and rejected — Linear's API doesn't expose the data needed to
distinguish reliably, and the scenario requires deliberate
operator action that happens to match this pattern.

The single source of truth for this format is the header comment of
`skills/sr-spec/scripts/coord_dep_scan.sh`, copied as a `## Audit
comment format` section into both `skills/sr-spec/SKILL.md`
(step 12) and `skills/close-issue/SKILL.md` (step 8) so each skill
is self-contained for a reader. `/sr-spec` (today) and `/sr-start`
once ENG-281 lands both produce the same format; `/close-issue`'s
cleanup parses identically regardless of which actor posted the
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

### 4. `/sr-spec` step 11 — reasoning, operator gate (skill prose)

Step 11 is **operator-interaction-only**. It builds an
`accepted_edges` list and persists it to a transport file at
`<worktree>/.sensible-ralph-coord-dep.json` so step 12 can pick it
up across the shell-process boundary. **No Linear writes** at step
11 — no comment, no relation-add, no label. All coord-dep
mutations defer to step 12 (finalize) where they participate in
the existing all-or-nothing-before-Approved sequence. This avoids
residue leakage if finalize fails or the operator abandons after
the scan.

1. **Label-existence preflight.** Verify the configured `coord-dep`
   label exists in the workspace:

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
   `/sr-start` would have step 12 try to apply a label that no-ops
   silently — leaving no operator signal if `/close-issue`'s
   cleanup later partially fails.

2. Run the helper:
   `bash "$CLAUDE_PLUGIN_ROOT/skills/sr-spec/scripts/coord_dep_scan.sh" "$SPEC_FILE" "${PREREQS[@]}"`.
   Capture the JSON bundle.

3. **Trivial fast path.** If `peers` is empty, or if every potential
   overlap maps to a parent already in `existing_blockers`, emit one
   line — `step 11: No coordination dependencies detected.` —
   leave `accepted_edges` empty, and proceed to step 12 (finalize).

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

6. **End of step 11: persist `accepted_edges` to the transport
   file.** Write the operator-confirmed edges to a JSON file at
   `<worktree>/.sensible-ralph-coord-dep.json`. Step 12 reads
   this file. The file format is a simple array of objects:

   ```json
   [
     { "parent": "ENG-X", "rationale": "both restructure lib/scope.sh's _scope_load function" },
     { "parent": "ENG-Y", "rationale": "ENG-Y renames foo.sh which this spec edits inline" }
   ]
   ```

   Even when zero candidates were accepted, write an empty array
   `[]` (not nothing) so step 12 can distinguish "step 11 ran and
   accepted nothing" (file exists, empty array) from "step 11
   never ran" (file absent — step 12 should treat that as the
   no-coord-dep case but log a diagnostic if the operator
   bypassed step 11).

   Cross-process semantics: each Bash tool call in `/sr-spec`'s
   skill prose is its own process. In-memory shell variables don't
   survive across calls. The transport file is the *only* reliable
   way to hand `accepted_edges` from step 11 to step 12.

   Shell-side state passed to step 12 via the dialogue:
   - `PREREQS` — design-time prerequisites declared at step 6
     (still in the operator's dialogue context; step 12 re-derives
     it from the conversation, same as it does today).
   - The transport file path (deterministic — derived from the
     worktree CWD at finalize time).

   Add `/.sensible-ralph-coord-dep.json` to the plugin's
   `.gitignore` (alongside the other gitignored runtime files
   listed in `docs/design/worktree-contract.md`'s "Required
   `.gitignore` entries" section). The file is per-issue,
   per-worktree, and ephemeral — successful finalize deletes it.

**Integration with finalize step 12.** Step 11 only stages
`accepted_edges` (in the transport file); step 12 absorbs the
writes into its existing sub-step 5 ("Push spec, set blockers,
verify"). Step 12's modified internal sequence:

1. **Read `accepted_edges` from the transport file.**

   ```bash
   COORD_DEP_FILE="$WORKTREE_PATH/.sensible-ralph-coord-dep.json"
   if [[ -f "$COORD_DEP_FILE" ]]; then
     accepted_parents=()
     while IFS= read -r p; do accepted_parents+=("$p"); done < <(
       jq -r '.[].parent' "$COORD_DEP_FILE"
     )
   else
     # No step-11 transport file present. Treat as no coord-dep edges.
     # Log a diagnostic if the operator skipped step 11 deliberately.
     accepted_parents=()
   fi
   ```

   `accepted_parents` is the parent-ID-only projection of the
   transport file's contents. The full `[{parent, rationale}, ...]`
   structure is needed when composing the audit comment in
   sub-step 6 below; keep the file path bound for that.

2. **Capture `INITIAL_BLOCKERS`** — current Linear `blocked-by`
   set at start of finalize. On a re-spec path the issue may
   already have prior-session blockers; this snapshot lets the
   verify step include them in `EXPECTED`.

   ```bash
   INITIAL_BLOCKERS=$(linear_get_issue_blockers "$ISSUE_ID" | jq -r '.[].id' | sort -u)
   ```

3. **Push spec description** (existing).

4. **Compute `ADD_LIST` and walk it (relation-adds first; comment
   posts AFTER).**

   ```bash
   ADD_LIST=$(printf '%s\n' "${PREREQS[@]+"${PREREQS[@]}"}" "${accepted_parents[@]+"${accepted_parents[@]}"}" \
     | sort -u | comm -23 - <(printf '%s\n' "$INITIAL_BLOCKERS"))
   ```

   `comm -23` filters out anything already in `INITIAL_BLOCKERS`
   so finalize doesn't attempt duplicate adds (Linear's behavior
   on duplicate `blocked-by` adds is unreliable across CLI
   versions — some error, some silently no-op).

   Track which adds succeed:

   ```bash
   committed_parents=()
   for parent in $ADD_LIST; do
     if linear issue relation add "$ISSUE_ID" blocked-by "$parent"; then
       committed_parents+=("$parent")
     else
       # Surface to operator: retry / skip-this-edge / abort finalize.
     fi
   done
   ```

   - **retry**: re-attempt the same parent.
   - **skip-this-edge**: REMOVE `$parent` from `accepted_parents`
     (so the audit comment in sub-step 6 won't list it) AND from
     `PREREQS` (if it originated there). Skip is "operator
     changed their mind in light of failure"; nothing claims this
     edge afterward.
   - **abort finalize**: stop the loop with whatever's in
     `committed_parents` so far. The audit comment has NOT been
     posted yet (we post it AFTER this loop), so successfully-added
     edges have NO audit trail — surface a recovery recipe (see
     sub-step 6 abort path).

   The comment-LAST ordering is deliberate. Posting the comment
   AFTER the relation-adds means the comment can list ONLY
   parents whose relations actually landed — eliminating the
   "skip leaves over-claim that cleanup later treats as
   destructive delete authority" failure mode. The trade-off: a
   comment-post failure after relation-adds succeed leaves
   relations without an audit trail, so `/close-issue`'s cleanup
   will not auto-discover them. Mitigation in sub-step 6.

5. **If `committed_parents` is empty AND `accepted_parents` was
   non-empty (i.e., every accepted edge failed and was skipped or
   the operator aborted with zero successful adds):** skip
   sub-step 6 (no audit comment to post — there's nothing to
   audit) and sub-step 7 (no label needed). Fall through to
   sub-step 8 (verify).

6. **If `committed_parents ∩ accepted_parents` is non-empty: post
   the audit comment.**

   Compose the comment using the format from "The audit-comment
   contract" above. Bullet lines list every committed coord-dep
   parent (rationales pulled from the transport file by parent
   ID). The structured ` ```coord-dep-audit ` block lists ONLY
   the committed coord-dep parents in `parents`.

   ```bash
   committed_coord_parents=$(comm -12 \
     <(printf '%s\n' "${committed_parents[@]+"${committed_parents[@]}"}" | sort -u) \
     <(printf '%s\n' "${accepted_parents[@]+"${accepted_parents[@]}"}" | sort -u))
   # Compose body using committed_coord_parents + transport file rationales.
   linear issue comment add "$ISSUE_ID" --body-file <tmp>
   ```

   **If comment-post fails:** the relations are already in Linear
   without an audit trail. Surface to operator with three choices:
   - **retry comment-post** (Linear API hiccups are usually
     transient; retry has high success rate).
   - **proceed-anyway**: print the comment body to the operator's
     session log; operator can manually post via Linear UI. Do NOT
     transition state. Issue stays `In Design`. The relations are
     orphaned-from-cleanup until the comment lands; document this
     in the operator-facing message and provide an exact recovery
     recipe (re-post the comment OR `linear issue relation delete`
     each committed parent).
   - **rollback**: walk `committed_parents`, attempt
     `linear issue relation delete` on each. Best-effort; surface
     residue. After rollback, issue stays `In Design`; operator
     can re-run `/sr-spec` (which detects In Design and resumes).

7. **If `committed_parents ∩ accepted_parents` is non-empty: add
   the coord-dep label** via `linear_add_label "$ISSUE_ID"
   "$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL"`. Idempotent. On
   failure: log; continue. The comment is the load-bearing
   artifact for cleanup, not the label.

8. **Verify** — compute `EXPECTED` as the union of `INITIAL_BLOCKERS`,
   `PREREQS`, and `committed_parents` (NOT `accepted_parents` —
   if the operator skipped some during the relation-add loop,
   those parents aren't in Linear and shouldn't be in EXPECTED):

   ```bash
   EXPECTED=$(printf '%s\n' \
     "${INITIAL_BLOCKERS[@]+"${INITIAL_BLOCKERS[@]}"}" \
     "${PREREQS[@]+"${PREREQS[@]}"}" \
     "${committed_parents[@]+"${committed_parents[@]}"}" \
     | sort -u)
   ACTUAL=$(linear_get_issue_blockers "$ISSUE_ID" | jq -r '.[].id' | sort -u)
   ```

   On mismatch: STOP. Do not transition state. The discrepancy
   means a relation-add silently failed (without our error
   detection catching it) or the issue's blocker set drifted
   mid-finalize; either is operator-investigable.

9. **On successful state transition (existing sub-step 6):
   delete the transport file.**

   ```bash
   rm -f "$WORKTREE_PATH/.sensible-ralph-coord-dep.json"
   ```

   Per-issue ephemeral state. If finalize fails before this point,
   the file persists — re-running `/sr-spec` (which detects In
   Design and resumes) will pick up the same `accepted_edges` and
   re-run the relation-adds with the duplicate-skip filter
   (`comm -23` against the now-larger `INITIAL_BLOCKERS`).

The `${arr[@]+"${arr[@]}"}` pattern expands to nothing when the
array is empty, sidestepping bash 3.2's unbound-variable fault
under `set -u`. Same pattern `lib/linear.sh::linear_add_label`
uses.

Call this contract out explicitly in the SKILL.md prose at both
step 11 (where `accepted_edges` is staged into the transport
file) and step 12 (where the file is read, relations are added,
and the audit comment is posted last).

### 5. `/close-issue` step 8 — cleanup helper

New file: `skills/close-issue/scripts/cleanup_coord_dep.sh`.

Inputs:

- Env: `$ISSUE_ID`, `$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL`.

Behavior:

```bash
# 1. Server-side query for comments containing the structured fence
#    language tag `coord-dep-audit`. linear's `issue comment list`
#    CLI truncates at ~50 with no cursor support
#    (see skills/prepare-for-review/SKILL.md), so on long-lived
#    issues older audit comments would be silently invisible.
#    Use `linear api` with body.contains filtered on the fence tag
#    — same pattern /prepare-for-review uses for its dedup check.
comments=$(linear api \
  --variable "issueId=$ISSUE_ID" \
  --variable "marker=coord-dep-audit" <<'GRAPHQL'
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

# 2. Refuse silent truncation. 250 audit-block-bearing comments on
#    a single issue is implausible; if it ever happens, fail loud
#    rather than work from incomplete data — the same posture
#    `linear_get_issue_blockers` and `linear_label_exists` take.
has_next=$(printf '%s' "$comments" | jq -r '.data.issue.comments.pageInfo.hasNextPage // false')
if [[ "$has_next" == "true" ]]; then
  echo "cleanup_coord_dep: audit-comment query truncated for $ISSUE_ID at 250 — aborting cleanup; investigate manually" >&2
  exit 1
fi

# 3. Extract parent IDs from `coord-dep-audit` fenced blocks ONLY.
#    The audit-comment contract (see "The audit-comment contract"
#    section) declares this fence as the cleanup-authoritative
#    source. Free-form prose mentioning the marker — bullet text,
#    inline references, even a backticked quote of the fence
#    language tag in a non-fenced context — is NOT delete authority.
#
#    awk extracts content between ```coord-dep-audit and the
#    matching ```. The blank-line emit on close tells jq -s where
#    one block ends so it can slurp them as separate JSON
#    documents. jq parses each block, unions parents, dedups.
#
#    Returns empty (no exit code) if no blocks found or all blocks
#    are malformed JSON — the cleanup's no-marker fast path runs.
#    A genuine `jq` parse error on a malformed block is suppressed
#    via `2>/dev/null` deliberately: an old / corrupted audit
#    comment shouldn'"'"'t block legitimate cleanup. (Operators
#    can investigate the comment by hand if cleanup is unexpectedly
#    inert.)
parents=$(printf '%s' "$comments" | jq -r '.data.issue.comments.nodes[].body' \
  | awk '/^```coord-dep-audit$/{flag=1; next} /^```$/{if(flag){print ""}; flag=0} flag' \
  | jq -rs '[.[] | (.parents // [])] | flatten | unique | .[]?' 2>/dev/null \
  | sort -u)

# Fast path: no marker matches → no edges to remove. Still attempt
# label-remove (idempotent), gated on linear_label_exists so a
# missing-workspace-label scenario takes the same skip-just-the-
# label-call posture as the success path below.
if [[ -z "$parents" ]]; then
  linear_label_exists "$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL" 2>/dev/null && \
    linear_remove_label "$ISSUE_ID" "$CLAUDE_PLUGIN_OPTION_COORD_DEP_LABEL" \
      || echo "cleanup_coord_dep: label removal skipped or failed (no edges to delete) — continuing" >&2
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
- **Zero-match safe under `set -euo pipefail`.** The
  `awk`/`jq -rs` extraction returns 0 even when no fenced blocks
  match; the no-audit-block path is the common case for issues
  without any coord-dep history and exits cleanly with the
  label-remove attempt.

**Documented edge case (not designed around):** if an operator
manually removes a coord-dep relation, then later re-adds the same
parent ID as a SEMANTIC `blocked-by` relation, this cleanup will
delete the (semantic) relation when the issue closes. The fenced
JSON `parents` array records IDs only — not the specific relation
instance — so cleanup can't distinguish "the relation we added"
from "a different relation later created with the same parent
ID." Workaround for operators repurposing a relation: edit the
audit comment to remove that parent from the `parents` array in
the ` ```coord-dep-audit ` block, OR delete the comment entirely.
Cost-of-fixing this algorithmically (e.g., embedding relation
`createdAt` timestamps in the JSON and matching against Linear's
relation metadata at delete time) outweighs the value — the
scenario is rare and requires deliberate operator action that
happens to match this specific pattern.

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
   Fixtures are GraphQL responses containing comment bodies with
   ` ```coord-dep-audit ` fenced JSON blocks. Asserts:
   - Zero matching comments → label-remove still attempted (gated
     on `linear_label_exists`), exit 0.
   - Multi-comment dedup works (same parent in fenced blocks
     across multiple matching comments collapses to one delete
     attempt).
   - Bullet text mentioning a parent ID is NOT extracted (only
     the JSON block is authoritative). A comment containing
     `- blocked-by ENG-Z — some rationale` but with NO
     `coord-dep-audit` block (or whose block doesn't include
     `ENG-Z` in `parents`) does NOT trigger a delete on `ENG-Z`.
   - Backticked or inline mention of `coord-dep-audit` outside a
     fenced block is NOT treated as authority.
   - Malformed JSON inside a fenced block is silently skipped
     (jq parse error is suppressed via `2>/dev/null`); cleanup
     proceeds based on whatever well-formed blocks remain.
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
     audit-block parents absent) → label removed, exit 0.
   - Workspace label missing on the success path → label-remove
     skipped (logged); exit 0 because relation-deletes still
     completed cleanly. Same applies to the no-fenced-block fast
     path.
   - GraphQL response-shape failure (e.g., missing
     `data.issue.comments.nodes`) propagates as a non-zero exit
     — must NOT be masked by silently treating it as "no edges
     to delete."

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
4. `skills/sr-spec/SKILL.md` documents step 11 as
   **operator-interaction-only** (label-existence preflight,
   structured-prompt checklist, per-candidate operator gate
   producing the `accepted_edges` list, audit-comment-format
   reference) with **no Linear writes** at step 11. Step 11 ends
   by writing `<worktree>/.sensible-ralph-coord-dep.json` (the
   transport file) so step 12 picks up the operator-confirmed
   edges across the shell-process boundary. Step 12 (finalize)
   sub-step 5 absorbs all coord-dep mutations in this order:
   (a) read `accepted_edges` from the transport file;
   (b) capture `INITIAL_BLOCKERS` (current Linear blocked-by set);
   (c) push spec description;
   (d) compute `ADD_LIST = (PREREQS ∪ accepted_parents) \
   INITIAL_BLOCKERS` and walk it with `linear issue relation add`
   (per-edge retry/skip/abort on failure; track `committed_parents`);
   (e) **if there were any committed coord-dep parents: post the
   audit comment LAST**, listing only `committed_parents ∩
   accepted_parents` and including the structured
   ` ```coord-dep-audit ` block as the cleanup-authoritative
   source. Comment-LAST eliminates the over-claim failure mode
   from skipped edges; the trade-off (rare comment-post failure
   leaves relations without an audit trail) is handled by an
   operator-facing recovery path: retry / proceed-anyway-with-
   manual-recipe / rollback;
   (f) if any committed coord-dep parents: `linear_add_label`
   (best-effort);
   (g) verify `ACTUAL == INITIAL_BLOCKERS ∪ PREREQS ∪ committed_parents`;
   (h) transition Approved;
   (i) on success, `rm -f` the transport file.
   Both step 11 and step 12 prose explicitly call out the
   defer-writes-to-finalize contract (writes do NOT happen at
   step 11) so the `In Design` issue is residue-free until finalize
   succeeds atomically. Step renumbering: existing step 11
   (finalize) becomes step 12; existing step 10 (codex) and all
   earlier numbers stay unchanged; informal "Spec self-review" and
   "User review gate" sections stay informal.

   The plugin's `.gitignore` (the canonical list per
   `docs/design/worktree-contract.md`'s "Required `.gitignore`
   entries") gains `/.sensible-ralph-coord-dep.json`. Update
   `worktree-contract.md`'s table to include the new entry.
5. `skills/close-issue/scripts/cleanup_coord_dep.sh` exists and
   implements the cleanup contract:
   - Queries audit-block-bearing comments via `linear api` with a
     `body.contains` filter on the fence language tag
     `coord-dep-audit` (NOT via `linear issue comment list`, which
     truncates at ~50 with no cursor support).
   - Refuses silent truncation when `pageInfo.hasNextPage=true`
     (exit 1, label retained).
   - Extracts parent IDs ONLY from ` ```coord-dep-audit ` fenced
     JSON blocks via `awk`+`jq -rs` (NOT from free-form bullet
     text, prose mentions, or any non-fenced content). The
     structured block is the cleanup-authoritative source per the
     "audit-comment contract"; bullet text is human-readable but
     NOT delete authority.
   - Attempts `linear issue relation delete` on every extracted
     parent (best effort), then **re-fetches** blockers and
     classifies failure from the post-delete state — NOT from a
     pre-delete snapshot. This is deliberate: a pre-fetch goes
     stale under concurrent UI edits and misclassifies completed
     cleanup as failure. Implementers MUST NOT reintroduce the
     pre-fetch-snapshot pattern.
   - Verifies workspace label exists (via `linear_label_exists`)
     before attempting `linear_remove_label` on BOTH the
     no-marker fast path AND the success path; skips just the
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
