# Hidden-dependency scan in `/sr-spec` and cleanup in `/close-issue`

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
  step 11     hidden-dependency scan         ← NEW
                ├─ skills/sr-spec/scripts/hidden_dep_scan.sh   (data assembly)
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
  step 8      hidden-dep cleanup             ← NEW
                └─ skills/close-issue/scripts/cleanup_hidden_dep.sh
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

```
**hidden-dependency**: blocked-by ENG-NNN
```

This exact string, anywhere in any comment body of any issue, is
owned by this feature. The single source of truth for the format is
the header comment of `skills/sr-spec/scripts/hidden_dep_scan.sh`,
copied as a `## Marker format` section into both
`skills/sr-spec/SKILL.md` (step 11) and `skills/close-issue/SKILL.md`
(step 8) so each skill is self-contained for a reader.

`/close-issue`'s cleanup will treat any line matching the regex

```
^[-[:space:]]*\*\*hidden-dependency\*\*:[[:space:]]+blocked-by[[:space:]]+ENG-[0-9]+
```

as a removal target, regardless of which scan posted it (`/sr-spec`
today, `/sr-start` once ENG-281 lands). Operators must not write the
marker by hand in a comment unless they want it auto-removed at
close.

## Components

### 1. Plugin option, defaults, preflight

Add a new `userConfig` option to `.claude-plugin/plugin.json`:

```json
"hidden_dep_label": {
  "type": "string",
  "title": "Hidden-dependency label",
  "description": "Label applied by /sr-spec when its hidden-dependency scan adds blocked-by edges; cleared by /close-issue (default: ralph-hidden-dep)",
  "default": "ralph-hidden-dep"
}
```

Mirror the default in `lib/defaults.sh` (the existing comment at the
top of that file says "The defaults mirror the plugin.json userConfig
defaults — update in lockstep"):

```bash
: "${CLAUDE_PLUGIN_OPTION_HIDDEN_DEP_LABEL=ralph-hidden-dep}"
# ...
export CLAUDE_PLUGIN_OPTION_HIDDEN_DEP_LABEL
```

Append `CLAUDE_PLUGIN_OPTION_HIDDEN_DEP_LABEL` to the hardcoded
`required_vars` array in
`skills/sr-start/scripts/lib/preflight_labels.sh::preflight_labels_check`:

```bash
local -a required_vars=(
  CLAUDE_PLUGIN_OPTION_FAILED_LABEL
  CLAUDE_PLUGIN_OPTION_STALE_PARENT_LABEL
  CLAUDE_PLUGIN_OPTION_HIDDEN_DEP_LABEL
)
```

The hardcoded list (rather than convention-based discovery) is
deliberate per that file's design note: explicit lists keep the set
of "things that must exist in Linear" auditable.

**Upgrade note** for the spec: workspaces upgrading the plugin must
create the `ralph-hidden-dep` workspace-scoped label once before the
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

New file: `skills/sr-spec/scripts/hidden_dep_scan.sh`. Pure data
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
  (the skill prose fast-paths to "No hidden dependencies detected").
- New spec file does not exist at the passed path → exit 2 with a
  "step 7 spec file missing" message (sanity check; should be
  impossible in normal flow).

The script writes nothing to Linear. All mutations happen in skill
prose after operator confirmation.

### 4. `/sr-spec` step 11 — reasoning and mutation (skill prose)

The skill's step 11 prose drives the rest:

1. Run the helper:
   `bash "$CLAUDE_PLUGIN_ROOT/skills/sr-spec/scripts/hidden_dep_scan.sh" "$SPEC_FILE" "${PREREQS[@]}"`.
   Capture the JSON bundle.

2. **Trivial fast path.** If `peers` is empty, or if every potential
   overlap maps to a parent already in `existing_blockers`, emit one
   line — `step 11: No hidden dependencies detected.` — and proceed
   to step 12 (finalize).

3. **Structured-prompt reasoning.** Present the new spec body and
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

4. **Per-candidate operator gate.** For each surviving candidate,
   show: parent ID + title, category (`path-collide` / `identifier`
   / `rename`), one-line rationale. Three choices:
   **accept / reject / edit-rationale**.

5. **Mutation per acceptance.** Walk accepted candidates one at a
   time:

   - `linear issue relation add "$ISSUE_ID" blocked-by "$PARENT"`.
   - On success: append `$PARENT` to in-shell `PREREQS`, append
     `{parent, rationale}` to local `committed_edges`.
   - On failure: surface to operator with three choices —
     **retry / skip-this-edge / abort-scan**. Don't silently swallow.

6. **Post-loop, if `committed_edges` is non-empty:**

   - Compose one consolidated comment in the format below.
   - `linear issue comment add "$ISSUE_ID" --body-file <tmp>`.
   - `linear_add_label "$ISSUE_ID" "$CLAUDE_PLUGIN_OPTION_HIDDEN_DEP_LABEL"`.
   - If the comment or label call fails: print the comment body
     inline so the operator can manually post; do NOT roll back
     relation-adds. Operator decides what to do next.

   Mutation order — **relations first, comment + label last** —
   chosen so the most-likely-failure (network/CLI hiccup on
   relation-add) leaves no orphaned audit trail. The reverse failure
   mode (relations succeed, comment fails) is rarer and surfaces
   clearly.

**Comment format** (Approach C — one consolidated comment per scan
run, marker repeats per line):

```
**hidden-dependency** edges added by /sr-spec scan:

- **hidden-dependency**: blocked-by ENG-X — both restructure `lib/scope.sh`'s `_scope_load` function
- **hidden-dependency**: blocked-by ENG-Y — ENG-Y renames `foo.sh` which this spec edits inline

Will be removed automatically on `/close-issue`.
```

Each line independently parseable by the cleanup helper's regex.
Multiple comments accumulate fine across re-spec sessions.

**Critical integration with finalize step 12:** the existing
finalize sub-step 5 verifies `ACTUAL` (post-add Linear blocker set)
matches `EXPECTED` (the in-shell `PREREQS` array). After step 11
mutates `PREREQS`, finalize sub-step 5 must continue to use the same
array — no re-initialization. Implementers must NOT shadow `PREREQS`
between steps. Call this out explicitly in the SKILL.md prose at
both step 11 and step 12.

### 5. `/close-issue` step 8 — cleanup helper

New file: `skills/close-issue/scripts/cleanup_hidden_dep.sh`.

Inputs:

- Env: `$ISSUE_ID`, `$CLAUDE_PLUGIN_OPTION_HIDDEN_DEP_LABEL`.

Behavior:

```bash
# 1. Pull all comments. linear comment list returns the full thread by default.
comments=$(linear issue comment list "$ISSUE_ID" --json) || {
  echo "cleanup_hidden_dep: failed to list comments on $ISSUE_ID — skipping cleanup" >&2
  exit 1
}

# 2. Per-line regex extraction across all comment bodies, dedup.
parents=$(printf '%s' "$comments" | jq -r '.nodes[].body' \
  | grep -Eo '\*\*hidden-dependency\*\*:[[:space:]]+blocked-by[[:space:]]+ENG-[0-9]+' \
  | grep -Eo 'ENG-[0-9]+' \
  | sort -u)

# 3. Best-effort relation removal.
for p in $parents; do
  linear issue relation delete "$ISSUE_ID" blocked-by "$p" \
    || echo "cleanup_hidden_dep: $p edge absent or delete failed — continuing" >&2
done

# 4. Best-effort label removal via lib helper.
linear_remove_label "$ISSUE_ID" "$CLAUDE_PLUGIN_OPTION_HIDDEN_DEP_LABEL" \
  || echo "cleanup_hidden_dep: label removal failed — continuing" >&2

exit 0
```

Three properties guaranteed:

- **Multi-comment safe.** All comments walked; all matched parent IDs
  collected into one set before deletion. N re-spec runs producing N
  comments → all parents removed in one pass.
- **Idempotent.** `sort -u` dedups across comments. Re-running
  `/close-issue` (e.g., after partial failure on the merge step
  earlier) is safe; already-deleted relations log a benign warning
  and the loop continues.
- **Conservative on failure.** Per-parent and label failures log and
  continue. Only a wholesale `comment list` failure exits non-zero —
  worth a warning back to `/close-issue`'s prose, but `/close-issue`
  treats non-zero as log-and-proceed-to-step-9.

`/close-issue`'s SKILL.md step 8 invokes the helper:

```bash
bash "$CLAUDE_PLUGIN_ROOT/skills/close-issue/scripts/cleanup_hidden_dep.sh" \
  || echo "close-issue: hidden-dep cleanup returned non-zero; proceeding to worktree teardown" >&2
```

Cleanup is housekeeping; the merge + `Done` are the load-bearing
mutations and have already landed.

## Edge cases

- **No Approved peers in scope.** Helper emits `peers: []`; skill
  prose fast-paths to "No hidden dependencies detected." Step 11
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
  description. Hidden-dep edges from the prior session are already
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
- **Operator manually edits a prior hidden-dep audit comment.** The
  marker regex still matches if the edit preserves the line format;
  edits that break the line format are picked up as zero matches and
  the corresponding edge stays at close. Document the marker as
  reserved; operators editing it bear consequences. Not a
  high-priority risk.
- **Marker text appears in a code fence inside a comment.** The
  regex matches across fence boundaries; the cleanup helper would
  treat it as a removal target. Mitigation: document that the marker
  is reserved anywhere in any comment body. Risk of accidental match
  in normal prose is low (the literal `**hidden-dependency**:
  blocked-by ENG-NNN` prefix is unusual).

## Testing

Three new bats files, integrated into the existing `lib/test/`
harness:

1. **`lib/test/linear_remove_label.bats`** — unit-tests the new
   `lib/linear.sh` helper. Mocks `linear` CLI calls; asserts:
   idempotent removal of present label, no-op on absent label, clear
   diagnostic on missing-workspace-label, propagation of API
   failures.

2. **`skills/sr-spec/scripts/test/hidden_dep_scan.bats`** —
   unit-tests the data-assembly helper. Mocks `linear` CLI for
   issue-list and issue-view; asserts: empty peer list emits valid
   JSON with `peers: []`, peer descriptions are passed through
   verbatim, `existing_blockers` excludes peers already declared
   (and the union with design-time PREREQS), self-exclusion (current
   `$ISSUE_ID` not in peer list), bad spec-file path returns exit 2.

3. **`skills/close-issue/scripts/test/cleanup_hidden_dep.bats`** —
   unit-tests the cleanup helper. Mocks `linear issue comment list`
   to return fixture comment threads; asserts: multi-comment dedup
   works, non-marker comments are ignored, malformed marker lines
   (e.g., wrong issue prefix, missing colon, code-fenced) are
   handled per the documented behavior, per-parent failure logs but
   doesn't abort, label removal failure logs but doesn't abort.

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
- Auto-removal of hidden-dep edges on re-spec when a re-spec scan
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

1. New `userConfig` option `hidden_dep_label` exists in
   `.claude-plugin/plugin.json` with default `ralph-hidden-dep`,
   mirrored in `lib/defaults.sh`.
2. `lib/linear.sh::linear_remove_label` exists, follows the
   `linear_add_label` pattern, returns 0 on success or no-op-on-absent,
   non-zero on workspace-label-missing or API failure.
3. `skills/sr-spec/scripts/hidden_dep_scan.sh` exists, takes the spec
   file path and design-time PREREQS as inputs, emits the documented
   JSON bundle on stdout, exits 0 on empty peers, 1 on Linear failure,
   2 on missing spec file.
4. `skills/sr-spec/SKILL.md` documents step 11 with the
   structured-prompt checklist, the per-candidate operator gate, the
   mutation order (relations first, then comment + label), the
   `PREREQS`-augmentation contract with step 12, and the comment
   format. Step renumbering: existing step 11 (finalize) becomes
   step 12; existing step 10 (codex) and all earlier numbers stay
   unchanged; informal "Spec self-review" and "User review gate"
   sections stay informal.
5. `skills/close-issue/scripts/cleanup_hidden_dep.sh` exists,
   implements the per-line regex parser, walks all comments, dedups
   parent IDs, removes edges and the label best-effort, exits 0
   except on wholesale comment-list failure.
6. `skills/close-issue/SKILL.md` documents step 8 (cleanup) and
   step 9 (reap codex broker + remove worktree — was step 8). The
   new step's prose includes the marker format and the contract
   with the scan.
7. `skills/sr-start/scripts/lib/preflight_labels.sh::preflight_labels_check`
   includes `CLAUDE_PLUGIN_OPTION_HIDDEN_DEP_LABEL` in `required_vars`.
8. `skills/sr-start/SKILL.md` Prerequisites lists the new
   `ralph-hidden-dep` workspace-scoped label setup command alongside
   the existing `ralph-failed` and `stale-parent` ones.
9. New bats files cover the helpers per the testing section.
10. Existing bats coverage for `lib/linear.sh`, `lib/preflight_labels.sh`,
    and the affected skills continues to pass.
11. After `/sr-spec` runs the scan and accepts edges on a test issue,
    a subsequent `/close-issue` correctly removes all the marked
    edges and the label.
