# Halt conditions for /prepare-for-review when discoveries block deliverability

ENG-245 — implementation spec.

## Problem

`/prepare-for-review` is the gate that transitions an issue from
`In Progress` → `In Review` at the tail of an autonomous ralph
session. Today it has no provision for halting: if a finding surfaces
during the codex review (Step 5) that indicates the feature being
reviewed does not actually meet its acceptance criteria, the skill
proceeds to post a handoff comment and transition to `In Review`
anyway, treating the finding as an "ambiguous" item to flag for the
human reviewer.

For findings that name design tradeoffs or deferred questions, that
behavior is correct — the human reviewer can adjudicate. For findings
that name a concrete bug whose existence means the feature does not
work, advancing to `In Review` is wrong: it tells the human "this is
ready to ship" when it isn't, and it advances the orchestrator's
DAG so descendant issues dispatch on top of broken work.

ENG-240 (Done) added the CLAUDE.md rule that classifies bug
discoveries by scope and routes out-of-scope bugs to a new Linear
issue. That covers *filing* the bug. It does not address whether the
ritual should halt because the bug exists. Halt-vs-continue depends
on ritual-specific semantics — does this bug block the acceptance
criteria for *this* ticket? — and so belongs in the skill, not in
CLAUDE.md.

## Solution overview

Split Step 5's existing two-bucket finding classification (`actionable`
+ `ambiguous`) into three buckets (`actionable` + `advisory` +
`deliverability-blocking`). The third bucket triggers a halt path:
file the discovered bug as a follow-up issue per ENG-240, set a
`blocked-by` relation on the current ticket, post a halt-specific
Linear comment with distinct structure, and exit clean — skipping the
regular Step 6 handoff comment and the Step 7 `In Review` transition.

The halt path **does not introduce a new orchestrator outcome class.**
The orchestrator already classifies "exit 0 + post-state ≠ In Review"
as `exit_clean_no_review`, applies `ralph-failed`, taints descendants,
and surfaces in `/sr-status`. That treatment is exactly what a halt
needs. The new halt comment supplies the operator triage context.

## Design

### Trigger detection (Step 5 finding classification)

Step 5 currently invokes `codex-review-gate` and processes findings
in two buckets. The new classification:

1. **Actionable** — clear defect within scope. Fix inline, commit,
   re-run codex. *Unchanged from today.*
2. **Advisory ambiguous** — needs human judgment but the deliverable
   still works. Capture in Step 6's `## Review Summary` for the
   reviewer; proceed to Step 6/7 normally. *This is today's
   "ambiguous" bucket, renamed.*
3. **Deliverability-blocking** — the discovery means the feature
   being reviewed does NOT meet its acceptance criteria, and the fix
   is out of scope for this ticket. **Halt path engages.**

Bucket 3 is a judgment call. Concrete examples to include in the
SKILL.md text so the agent has a reference:

- Codex shows the new endpoint silently returns the wrong shape
  because of a bug in a shared serializer this ticket didn't touch.
- Codex shows the new feature relies on a config flag that's never
  set anywhere — code reads it but no caller writes it.
- The spec promised behavior X but X requires a missing helper that
  this ticket's scope didn't add.

The agent's classification rule, applied in this strict order
(first match wins):

1. **Is the bug fix in code touched by this ticket's commits?** That
   is, would the fix be a modification to a file/region that this
   ticket's branch already adds or modifies relative to
   `$BASE_SHA..HEAD`? If yes — bucket 1 (fix inline; the active spec
   covers this code by the user-global CLAUDE.md "current task's
   scope" definition).
2. **Else, does the finding invalidate the feature's acceptance
   criteria?** I.e. would a reviewer reading the issue description
   conclude the feature does not deliver what was promised? If yes —
   bucket 3 (halt).
3. **Else** — bucket 2 (advisory: design tradeoff, stylistic concern,
   deferred consideration, non-blocking edge case; capture in
   summary, proceed).

**When uncertain at any step, escalate to the higher-numbered
bucket.** Specifically:
- Uncertain between bucket 1 and bucket 3 — default to bucket 3.
  This matches the user-global CLAUDE.md rule "when uncertain, treat
  as out of scope," and silently fixing off-ticket code conflates
  in-scope and out-of-scope work in a single commit, which the
  reviewer cannot easily separate.
- Uncertain between bucket 2 and bucket 3 — default to bucket 3.
  Rationale: a false-positive halt costs operator triage time. A
  false-negative ship of a broken feature costs more — the DAG
  advances, descendants dispatch onto bad work, and the
  orchestrator's post-dispatch checks have no way to recover.

The location-first ordering (step 1 before step 2) is deliberate. A
finding can be "the agent could technically fix this" *and* "this
breaks deliverability" simultaneously when the bug is inside the
ticket's own code — that's exactly bucket 1, and codex's
fix-and-re-run loop is the right response. Only when the bug is
*outside* the ticket's code does the deliverability question route
to bucket 3 (halt) vs bucket 2 (advisory).

### Interactive vs autonomous behavior

The halt path is binary — if any finding is classified bucket 3,
halt fires once for the run. The interactive-mode prompt is the only
behavioral difference between modes; the rest of the halt path is
identical.

#### Autonomous-mode detection

The skill detects autonomous mode by checking for the autonomous
preamble's environment marker. The orchestrator MUST export
`SENSIBLE_RALPH_AUTONOMOUS=1` into the dispatched `claude -p`
process's environment when prepending the autonomous preamble.
Implementation surface: a one-line addition to
`skills/sr-start/scripts/orchestrator.sh` at the dispatch site,
before the `claude -p` invocation. (If the orchestrator already
exports a different name, use that — the implementer should grep
for an existing autonomous flag before adding a new one. If found,
this spec's `SENSIBLE_RALPH_AUTONOMOUS` reference becomes that
existing variable name; if not found, add `SENSIBLE_RALPH_AUTONOMOUS`
to the orchestrator and to the autonomous-mode design doc.)

The skill's halt-path logic branches on:

```bash
if [ "${SENSIBLE_RALPH_AUTONOMOUS:-}" = "1" ]; then
  AUTONOMOUS=1
else
  AUTONOMOUS=0
fi
```

This is a hard contract, not an inferred behavior. The agent does
NOT infer autonomous-vs-interactive from preamble presence in
context, because that inference can fail silently: the agent might
prompt anyway, the autonomous session has no stdin to receive an
answer, the prompt sits as the session's last text without a tool
call, and the orchestrator classifies the run as
`exit_clean_no_review` — same final classification as a clean halt,
but without the halt comment having posted. The env var collapses
that failure mode to a deterministic branch.

#### Autonomous mode (`AUTONOMOUS=1`)

No prompt. The agent's bucket-3 judgment is final and the halt path
engages immediately. This matches the autonomous preamble's
escape-hatch pattern documented in `docs/design/autonomous-mode.md`:
when human input would normally be required, the autonomous session
takes the deterministic exit path.

#### Interactive mode (`AUTONOMOUS=0`)

The agent collects all bucket-3 findings from the current codex
pass, presents them together, and asks once:

> I'm classifying the following codex finding(s) as
> deliverability-blocking:
> - *<one-sentence why for finding 1>*
> - *<one-sentence why for finding N>*
>
> Halt? `[Y/n]`

Default Y. If the user answers `n`, all listed findings move to
bucket 2 (advisory) and Step 5 continues. If the user answers `y`
(or default), the halt path engages once with all listed findings
folded into the single halt comment's "Blocking discoveries"
section.

### Halt path mechanics

The halt path is a small idempotent state machine. Each execution
brings the issue from "halt decided" toward "halt fully recorded."
The state machine has three durable artifacts on the parent issue:

- **A** — one follow-up Linear issue per bucket-3 finding, each
  carrying a per-finding **provenance key** in its description.
- **B** — one `blocked-by` relation per follow-up, on the parent
  issue.
- **C** — exactly one halt comment on the parent issue, identified
  by its halt-specific revision footer.

A run that completes all three has fully recorded the halt. A run
that interrupts after some subset of A/B/C has been written must,
on retry, reconcile (not duplicate) the existing artifacts.

#### Provenance key (per-finding dedup)

Each bucket-3 finding gets a stable provenance key derived from its
content. The key MUST be deterministic for the same finding and MUST
change if the finding text changes. Recommended construction:

```bash
FINDING_KEY=$(printf '%s' "$finding_body" | shasum -a 256 | cut -c1-12)
PROVENANCE_TAG="<!-- halt-finding: ${ISSUE_ID}/${FINDING_KEY} -->"
```

`$ISSUE_ID` is the parent (the ticket prepare-for-review is running
on); `$FINDING_KEY` is the per-finding hash. `$PROVENANCE_TAG` is
embedded in the follow-up's description (Linear renders HTML
comments invisibly, per a known Linear behavior — but this spec only
relies on the substring being searchable, not invisible. If Linear
ever renders the tag literally, the key is still searchable; UX
degrades but correctness holds).

The marker text choice (`<!--` style) is a recommendation. The
implementer MAY substitute another searchable marker (e.g. a
fenced code block, a footer line) as long as it satisfies: (1)
unique enough to not match unrelated comments, (2) survives Linear's
markdown rendering, (3) queryable via the Linear API's `body.contains`
filter.

#### Reconcile-or-create algorithm (run for each bucket-3 finding)

```text
For each bucket-3 finding:
  Compute FINDING_KEY and PROVENANCE_TAG.
  Search for an existing follow-up issue whose description contains
    PROVENANCE_TAG.
  If found:
    Capture its issue ID as $blocker_id.
    Skip create.
  Else:
    Create the follow-up. Capture the new ID as $blocker_id.
    Embed PROVENANCE_TAG in the description (and the body the agent
    wrote per linear-workflow conventions).
  Append $blocker_id to $BLOCKER_ISSUE_IDS.
  linear issue relation add "$ISSUE_ID" blocked-by "$blocker_id"
```

The `relation add` call is idempotent on the Linear side: re-adding
an existing `blocked-by` relation does not create a duplicate and
exits 0. (The CLI does print "Created" on both first-add and re-add,
which is misleading if you treat output as a truthful signal — but
the underlying state is correct either way. Trust the post-condition,
not the CLI's return surface; if a separate verification is needed
elsewhere, query `linear_get_issue_blockers "$ISSUE_ID"`.)

So the relation step needs no pre-check for partial-failure retry.
Only the follow-up issue creation needs the provenance-key dedup,
because Linear *will* let you create a second issue with identical
content if you call `issue create` twice.

Reconciling existing follow-ups is what makes the halt path safely
re-runnable. A retry after partial-failure re-discovers the
already-filed issues by their provenance keys, fills in missing
relations idempotently, and proceeds to step 3 below — without
duplicating any Linear state.

Linear API search query for the existing-follow-up check:

```bash
linear api 'query($q: String!) { issues(filter: { description: { contains: $q } }, first: 5) { nodes { identifier } } }' \
  --variable "q=$PROVENANCE_TAG" \
  | jq -r '.data.issues.nodes[].identifier' | head -1
```

This query runs via the Linear API surface used elsewhere in the
plugin's `lib/linear.sh`.

#### Halt path execution order

Run these in order. Each step is idempotent per the algorithm
above; on retry, completed steps no-op.

1. **Reconcile-or-create the follow-up issues** (loop above).
   Output: `$BLOCKER_ISSUE_IDS` populated with one ID per
   bucket-3 finding.
2. **Reconcile-or-add `blocked-by` relations** (also handled by
   the loop above).
3. **Post the halt-specific comment** (template below) via
   `linear issue comment add --body-file` from a `mktemp`
   tempfile. The halt comment has its own SHA-anchored dedup
   (see "Dedup compatibility" below) — on retry, if the halt
   comment for the current HEAD is already posted, skip.
4. **Exit clean** with exit code 0. Do NOT run the regular
   Step 6 (handoff comment) or Step 7 (state transition). The
   issue stays in `In Progress`. The orchestrator's outcome
   classification picks this up as `exit_clean_no_review`
   (existing logic in `docs/design/outcome-model.md`).

The halt path is the skill's terminal path for this invocation. Per
the existing "Terminal action contract" section, the skill's last
operation must be a tool call (the halt comment post; or, on a
fully-reconciled retry where step 3's dedup hits, the search query
that confirmed the existing comment), not a markdown summary.

### Halt comment template

Posted via `linear issue comment add --body-file`. Body:

```markdown
## Halt — deliverability blocked

`/prepare-for-review` halted because a discovery during the codex
review indicates the feature does not meet its acceptance criteria.
The issue remains in `In Progress`; do NOT merge.

**Blocking discoveries:**

- *<one-paragraph description of finding 1>* — filed as
  [ENG-AAA](<linear url>) (`blocked-by` set on this issue)
- *<one-paragraph description of finding N>* — filed as
  [ENG-NNN](<linear url>) (`blocked-by` set on this issue)

**Why these block deliverability:** <one-paragraph reasoning the
agent applied to classify the finding(s) as bucket 3 — one
paragraph total, not one per finding>

**Resume conditions:** <what needs to land before this ticket can
be re-attempted — typically "all listed follow-ups merged" but may
include caveats>

## Commits in this branch

<git log --oneline $BASE_SHA..HEAD output>

---
_Posted by `/prepare-for-review` halt path for revision `<SHA>`_
```

For the single-finding case, the "Blocking discoveries" list still
renders correctly with one bullet — no separate single-finding
template variant.

The footer's `halt path for revision \`<SHA>\`` substring is the
dedup marker for the halt comment, distinct from the regular handoff
comment's `for revision \`<SHA>\``. The pre-post dedup query checks
for the halt-path marker specifically (see "Dedup compatibility"
below).

### Dedup compatibility

Step 6's existing dedup uses a SHA-based substring marker that
unintentionally matches BOTH the regular handoff comment and the
new halt comment, because both footers contain `` revision `<SHA>` ``.
That is a real correctness bug for the same-SHA retry case once the
halt path exists, AND for the case where one invocation at SHA X
posts a regular handoff comment (e.g., user demoted bucket-3
findings interactively) and a later invocation at the same SHA
classifies the same findings as bucket 3 and engages the halt path.
Both can happen, despite the previous version of this spec assuming
they couldn't.

**Resolution:** make the two markers disjoint by anchoring on the
comment-type substring, not on `revision`. Update both Step 6 and
the halt path to use markers that do not overlap.

#### Step 6 marker (REGULAR)

Update Step 6's dedup snippet from:

```bash
MARKER=$(printf 'revision `%s`' "$CURRENT_SHA")
```

to:

```bash
REGULAR_MARKER=$(printf 'Posted by `/prepare-for-review` for revision `%s`' "$CURRENT_SHA")
```

Step 6's existing footer line — `` _Posted by `/prepare-for-review`
for revision `<SHA>`_ `` — already contains this substring, so no
footer change is needed; only the dedup query's `marker` variable
narrows.

#### Halt path marker (HALT)

Halt comment footer (already specified):

```
_Posted by `/prepare-for-review` halt path for revision `<SHA>`_
```

Halt-path dedup snippet (run before posting in halt path step 3):

```bash
HALT_MARKER=$(printf 'Posted by `/prepare-for-review` halt path for revision `%s`' "$CURRENT_SHA")
HALT_ALREADY_POSTED=$(linear api 'query($issueId: String!, $marker: String!) { issue(id: $issueId) { comments(filter: { body: { contains: $marker } }, first: 1) { nodes { id } } } }' \
  --variable "issueId=$ISSUE_ID" \
  --variable "marker=$HALT_MARKER" 2>/dev/null \
  | jq '((.data.issue.comments.nodes) // []) | length > 0')
if [ "$HALT_ALREADY_POSTED" = "true" ]; then
  echo "halt comment for $CURRENT_SHA already posted; skipping repost" >&2
  exit 0
fi
```

The two markers are disjoint: `Posted by /prepare-for-review for
revision <SHA>` (regular) vs `Posted by /prepare-for-review halt path
for revision <SHA>` (halt). Neither is a substring of the other, so
each dedup query matches exactly one comment type.

#### Same-SHA path transition behavior

With disjoint markers, the dedup interaction is well-defined for the
case where the same SHA sees both decisions across separate
invocations:

- **Run A at SHA X posts a regular handoff comment** (e.g., user
  demoted bucket-3 findings interactively): `REGULAR_MARKER` matches
  on retry of Step 6, but `HALT_MARKER` does NOT match.
- **Run B at SHA X engages the halt path**: `HALT_MARKER` does not
  match the regular comment, so the halt path proceeds, posts the
  halt comment, and exits. The issue now carries both comments.
  Operator sees the halt comment as the most recent and acts on it.
- **Run B's earlier reconcile-or-create loop** finds the previously
  filed follow-ups (by provenance key) — even if Run A had filed
  none (because A demoted to advisory), Run B's loop creates them
  cleanly.
- **Run C at SHA X is another retry of the halt path**:
  `HALT_MARKER` matches → step 3 skips repost → exit clean. Run C
  may still execute the reconcile-or-create loop (steps 1–2)
  idempotently; that's harmless because the loop's existing-issue
  check finds the already-filed follow-ups and no-ops.

The transition from advisory to halt at the same SHA is allowed and
recorded by both comments existing on the issue. The reverse
transition (halt → advisory at same SHA) is not supported in
autonomous mode, because once the halt path has filed follow-ups
and posted the halt comment, the run is terminal. In interactive
mode, if the user changes their mind after a halt comment was posted,
manual cleanup is required (delete the halt comment, cancel the
follow-up issues, remove the blocked-by relations) — this spec
considers that flow out of scope; file separately if it becomes a
real workflow.

#### Implementation note for SKILL.md

The SKILL.md edit must update Step 6's `MARKER` line to the new
`REGULAR_MARKER` value. This is a behavioral change to existing
dedup logic (it narrows the match), and it is correct: today's
broader marker matches halt comments that don't yet exist, and
once they do, the existing logic would be wrong. The narrowing is
forward-compatible — comments posted before this change still match
because their footers contain the new marker substring verbatim.

### Terminal action contract update

The existing "Terminal action contract" section enumerates legal
final actions (1–3). Add a fourth:

> 4. **Halt path** — the halt comment post (`linear issue comment
>    add` for the halt template) followed by clean exit, after
>    `linear issue relation add ... blocked-by` has set the durable
>    halted-on-blocker record. The issue remains in
>    `$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE`. The orchestrator
>    classifies the run as `exit_clean_no_review` and applies
>    `ralph-failed`; that label is the operator triage signal,
>    consistent with the existing classification in
>    `docs/design/outcome-model.md`.

The illegal-final-action rule is unchanged: a markdown summary as
the session's last output is still illegal, including in the halt
path. The terminal tool call in the halt path is the
`linear issue comment add` of the halt comment.

### "Red Flags / When to Stop" update

The existing "Red Flags" section lists stop conditions that exit
per the existing precondition-failure handlers (typically
`exit 1`). The halt path is **not** one of those: it exits 0 on
success (the halt completed cleanly) so the orchestrator's
classification reads `exit_clean_no_review` and applies the
operator-triage label, not a hard-failure signal.

Add a clarifying note to the Red Flags section:

> The halt path (Step 5 bucket-3 finding) is a *legitimate* exit,
> distinct from the precondition failures listed above. Its
> terminal action is the halt comment post, and its exit code is
> 0. The orchestrator's post-dispatch state read sees the issue
> still in `In Progress` and classifies the run as
> `exit_clean_no_review` — same operator triage path as a
> hard failure, but reached deliberately.

## Implementation

### Files touched

- `skills/prepare-for-review/SKILL.md` — primary edit. Changes:
  - Step 5 narrative — split the ambiguous bucket per "Trigger
    detection" and document the location-first precedence rule.
  - New "Halt path" subsection under Step 5 — implements the
    mechanics in "Halt path mechanics", the reconcile-or-create
    algorithm, the autonomous-mode env-var detection, and the
    "Halt comment template".
  - Step 6 dedup marker — change `MARKER` from `'revision \`%s\`'`
    to the `REGULAR_MARKER` form per "Dedup compatibility".
  - "Terminal action contract" — add legal final action 4.
  - "Red Flags / When to Stop" — add the clarifying note.
  - Top-of-file checklist — update Step 5's entry to mention the
    bucket split and add the halt-path sub-checklist.
- `skills/sr-start/scripts/orchestrator.sh` — one-line addition at
  the dispatch site to export `SENSIBLE_RALPH_AUTONOMOUS=1` (or the
  equivalent existing variable, if one is already exported and the
  implementer prefers reuse) into the `claude -p` subprocess
  environment.
- `docs/design/autonomous-mode.md` — reference the env-var contract
  in a one-paragraph addition under "How the preamble is delivered"
  (or a new "Autonomous-mode signal" subsection). Keep the existing
  description of the preamble itself unchanged. Skip this update if
  the implementer reused an existing variable already documented in
  this design doc.

No other files are touched.

### Step-by-step implementation order

1. **Confirm or add the autonomous-mode signal.** Grep
   `skills/sr-start/scripts/orchestrator.sh` for an existing
   autonomous flag. If found, treat that as the signal name and
   skip the orchestrator edit. If not found, add the
   `SENSIBLE_RALPH_AUTONOMOUS=1` export at the dispatch site.
   Update `docs/design/autonomous-mode.md` to reference the chosen
   variable.
2. **Update Step 6's dedup marker** in
   `skills/prepare-for-review/SKILL.md` to `REGULAR_MARKER` per
   "Dedup compatibility". Verify the existing footer line already
   contains the new marker substring (it does; this is a no-op for
   pre-existing comments).
3. **Update the "Terminal action contract"** to add legal final
   action 4. This is the contract every other change must comply
   with.
4. **Update Step 5's narrative** to introduce the three-bucket
   classification with the location-first precedence rule. Keep
   the actionable-bucket flow (fix and re-run) verbatim.
5. **Add the new "Halt path" subsection** under Step 5. Include:
   - The autonomous-mode env-var detection snippet.
   - The interactive-mode prompt block.
   - The provenance-key construction.
   - The reconcile-or-create algorithm (issues + relations).
   - The halt comment template with `HALT_MARKER`.
   - The halt-path dedup pre-check.
6. **Update the "Red Flags / When to Stop"** section with the
   clarifying note about halt being a legitimate exit.
7. **Update the top-of-file checklist** to reflect the new Step 5
   structure (bucket split + halt-path sub-checklist).
8. **Read the updated SKILL.md end-to-end.** Verify: the three
   buckets are unambiguous, the halt path is reachable in both
   autonomous and interactive modes, the reconcile-or-create
   algorithm covers the partial-failure retry, the dedup markers
   are disjoint, the terminal contract enumerates exactly four
   legal final actions, and no path produces an illegal terminal
   summary.

### Acceptance criteria

- `skills/prepare-for-review/SKILL.md` describes a three-bucket
  finding classification in Step 5, with the location-first
  precedence rule documented (in-ticket-code → bucket 1; else
  deliverability check → bucket 3 vs 2).
- The "Halt path" subsection specifies:
  - The autonomous-mode detection contract via
    `SENSIBLE_RALPH_AUTONOMOUS` (or equivalent reused variable).
  - The interactive-mode prompt block.
  - The per-finding provenance-key construction.
  - The reconcile-or-create algorithm for both follow-up issues
    and `blocked-by` relations.
  - The four-step execution order (reconcile-or-create issues,
    reconcile-or-add relations, post halt comment with dedup
    pre-check, exit clean).
- Step 6's dedup marker is updated to `REGULAR_MARKER`
  (`'Posted by \`/prepare-for-review\` for revision \`%s\`'`).
- The halt-path dedup snippet uses the disjoint `HALT_MARKER`
  (`'Posted by \`/prepare-for-review\` halt path for revision \`%s\`'`).
- The halt comment template is verbatim in the SKILL.md, including
  the multi-finding "Blocking discoveries" list and the halt-path
  revision footer.
- The "Terminal action contract" enumerates legal final actions
  1–4, with the halt path as #4.
- The top-of-file checklist reflects the bucket split and the
  halt-path sub-checklist entry.
- The "Red Flags / When to Stop" section clarifies that the halt
  path is a legitimate exit, not a precondition failure.
- `skills/sr-start/scripts/orchestrator.sh` exports the autonomous
  signal (or already does — implementer's call).
- `docs/design/autonomous-mode.md` references the autonomous signal
  variable name (or already does).

The work is done when an autonomous session reading SKILL.md can,
without further human input:

- Classify a codex finding into one of the three buckets via the
  location-first rule.
- Detect autonomous-vs-interactive via the env-var signal.
- Engage the halt path correctly when bucket 3 fires, including
  partial-failure retry safety.
- Produce one of the four legal terminal actions.

## Out of scope

The following are explicitly out of scope for this ticket. File as
separate follow-ups if/when needed:

- **Halt logic in `/close-issue` or the project-local `close-branch`
  skill.** By the time those run, the human has already reviewed and
  approved. Halt at close time would have different design questions
  (which layer owns the gate — the cross-project Linear ritual or the
  project-local merge skill).
- **CLAUDE.md changes.** ENG-240 owns those.
- **A new orchestrator outcome class** for halts. The existing
  `exit_clean_no_review` is sufficient. If operator triage volume
  later shows a halt-vs-real-failure distinction is needed, file
  separately.
- **Resume automation.** The operator drives resume manually
  (remove `ralph-failed`, fix blocker, re-queue).
- **A halt trigger from steps other than Step 5.** Steps 1–4
  (doc-related sub-skills) don't surface deliverability bugs in
  practice. Generalizing the halt to those steps is unused mass.
- **Manual dogfood test** of the halt path. File a separate ticket
  if the codex review of this spec recommends one.

## Testing

This ticket is a SKILL.md edit. There is no code under test. The
verification surfaces are:

- **Spec self-review** (within `/sr-spec` Step 8): scan the SKILL.md
  for placeholders, internal contradictions, and ambiguities. Fix
  inline.
- **Codex review gate** (within `/sr-spec` Step 10): adversarial
  probing of this spec against `$SPEC_BASE_SHA`. The codex review
  is the primary safety net for catching mechanism-level defects in
  the SKILL.md prose before dispatch.
- **End-to-end manual verification** (out of scope; file separate
  if needed): construct a contrived branch where codex finds a
  bucket-3 issue; run `/prepare-for-review`; verify the halt
  comment posts, the `blocked-by` relation is set, and the issue
  stays `In Progress`.

## See also

- `docs/design/autonomous-mode.md` — the escape-hatch pattern this
  halt path extends.
- `docs/design/outcome-model.md` — the `exit_clean_no_review`
  classification that the halt path produces.
- `skills/prepare-for-review/SKILL.md` — the file being edited.
- ENG-240 — the CLAUDE.md rule classifying bug discoveries by scope
  that this halt path's "file a follow-up" step relies on.
