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

The agent's classification rule:

- If the finding describes a missing piece, broken contract, or
  unsatisfied precondition that the feature *requires* to deliver
  its acceptance criteria — bucket 3.
- If the finding describes a design tradeoff, a stylistic concern, a
  deferred consideration, or a non-blocking edge case — bucket 2.
- If the finding describes something the agent could fix in this
  ticket's scope — bucket 1 (the existing fix-and-re-run path).

**When uncertain between bucket 2 and bucket 3, default to bucket 3
(halt).** Rationale: a false-positive halt costs operator triage
time. A false-negative ship of a broken feature costs more — the DAG
advances, descendants dispatch onto bad work, and the orchestrator's
post-dispatch checks have no way to recover.

### Interactive vs autonomous behavior

**Autonomous mode** (the orchestrator-prepended preamble is loaded
into the session): no prompt. The agent's bucket-3 judgment is final
and the halt path engages immediately. This matches the autonomous
preamble's escape-hatch pattern documented in
`docs/design/autonomous-mode.md`: when human input would normally be
required, the autonomous session takes the deterministic exit path.

**Interactive mode** (no preamble; user at the keyboard): the halt
path is binary — if any finding is classified bucket 3, halt fires
once for the run. The agent collects all bucket-3 findings from the
current codex pass, presents them together, and asks once:

> I'm classifying the following codex finding(s) as
> deliverability-blocking:
> - *<one-sentence why for finding 1>*
> - *<one-sentence why for finding N>*
>
> Halt? `[Y/n]`

Default Y. If the user answers `n`, all listed findings move to
bucket 2 (advisory) and Step 5 continues. If the user answers `y`
(or default), the halt path engages once with all listed findings
folded into the single halt comment's "Blocking discovery" section.

This branch must not deadlock the autonomous session — the autonomous
preamble already converts "STOP and ask" patterns to the escape
hatch, and the halt path *is* the escape hatch in this case. The
interactive prompt only fires when the preamble is not loaded.

### Halt path mechanics

When the halt fires, run these in order. The mechanics are
count-agnostic: if a single bucket-3 finding triggers the halt, the
loops below execute once. If multiple bucket-3 findings are present,
each finding gets its own follow-up issue and its own blocked-by
relation, and the halt comment lists all of them.

1. **For each bucket-3 finding, file a follow-up issue.** The act
   of filing is required by ENG-240's CLAUDE.md rule (out-of-scope
   bugs → file a ticket). The follow-up's *format* follows the
   global `linear-workflow` skill's "Creating Issues" / "Follow-ups"
   conventions: provenance prefix
   `**Discovered during ENG-XXX prepare-for-review.**` (where
   `ENG-XXX` is the ticket prepare-for-review is running on, not
   the new follow-up); state `Todo` (the discovery is a concrete
   actionable bug, not vague backlog material); priority `Urgent`
   if the discovery is a bug, `Medium` otherwise; no assignee. If
   the linear-workflow skill is updated, follow whatever it says
   at invocation time — this spec does not duplicate the full rule
   set. Collect each new issue ID in shell as
   `$BLOCKER_ISSUE_IDS` (a list).
2. **For each follow-up, set a `blocked-by` relation** on the
   current ticket:
   ```bash
   for blocker in "${BLOCKER_ISSUE_IDS[@]}"; do
     linear issue relation add "$ISSUE_ID" blocked-by "$blocker"
   done
   ```
   These are the durable records of why the parent halted. They
   survive across sessions and are what `/sr-start`'s queue logic
   will see.
3. **Post the halt-specific comment** (template below) via
   `linear issue comment add --body-file` from a `mktemp` tempfile.
   Reuses Step 6's tempfile pattern. The comment lists all
   bucket-3 findings and their follow-up issue IDs.
4. **Exit clean.** Do NOT run the regular Step 6 (handoff comment)
   or Step 7 (state transition). The issue stays in
   `In Progress`. The orchestrator's outcome classification picks
   this up as `exit_clean_no_review` (existing logic in
   `docs/design/outcome-model.md`).

The halt path is the skill's terminal path for this invocation. Per
the existing "Terminal action contract" section, the skill's last
operation must be a tool call (the halt comment post or the relation
write), not a markdown summary.

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

Step 6 currently has SHA-based dedup:

```bash
MARKER=$(printf 'revision `%s`' "$CURRENT_SHA")
ALREADY_POSTED=$(linear api ... \
  --variable "marker=$MARKER" ...)
```

The marker `` revision `<SHA>` `` matches both the regular handoff
comment and the new halt comment, since both include that substring
in their footer. That's a problem on retry: if a halt comment is
already posted at HEAD and the agent re-runs (e.g., after a transient
failure), the regular Step 6 dedup would incorrectly conclude "we
already posted at this SHA" and skip — but the regular handoff isn't
the right comment to skip-into; the issue should remain halted.

**Resolution:** the halt path uses its own dedup marker:
`` halt path for revision `<SHA>` ``. The halt-path entry runs its
own dedup pre-check with this distinct marker before posting:

```bash
HALT_MARKER=$(printf 'halt path for revision `%s`' "$CURRENT_SHA")
HALT_ALREADY_POSTED=$(linear api ... --variable "marker=$HALT_MARKER" ...)
if [ "$HALT_ALREADY_POSTED" = "true" ]; then
  echo "halt comment for $CURRENT_SHA already posted; skipping repost" >&2
  exit 0
fi
```

The regular Step 6 dedup is unchanged — it continues to match
`` revision `<SHA>` ``, which matches both comment types. The
asymmetry is deliberate:

- A halt comment at SHA X having been posted does NOT suppress a
  later halt comment at the same SHA (the halt-path dedup catches
  that), AND does NOT suppress the regular Step 6 path (because the
  halt path exits before Step 6 runs at all — Step 6 never sees the
  halt comment).
- A regular handoff comment at SHA X having been posted DOES match
  Step 6's dedup. That's correct: if Step 6 already ran, we don't
  need to re-post.

In practice the regular and halt paths are mutually exclusive within
a single Step 5 invocation, so the dedup interaction matters only on
retry across separate invocations on the same HEAD. The halt path's
own dedup handles the halt-retry case; the regular Step 6 dedup
handles the regular-retry case. The two paths cannot both have run
on the same HEAD.

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

- `skills/prepare-for-review/SKILL.md` — primary edit. All changes
  in one file:
  - Step 5 narrative — split the ambiguous bucket as described in
    "Trigger detection".
  - New "Halt path" subsection under Step 5 — implements the
    mechanics in "Halt path mechanics" and "Halt comment template".
  - "Terminal action contract" — add legal final action 4.
  - "Red Flags / When to Stop" — add the clarifying note.
  - Top-of-file checklist — update Step 5's checklist entry to
    mention the bucket split, and add a new checklist entry (or
    sub-bullet) for the halt path's tool calls.

No other files are touched. No code changes outside SKILL.md.

### Step-by-step implementation order

1. Update the "Terminal action contract" section first — it's the
   contract every other change must comply with, and it's the
   reference the agent will look up if uncertain.
2. Update Step 5's narrative to introduce the three-bucket
   classification. Keep the actionable-bucket flow (fix and
   re-run) verbatim.
3. Add the new "Halt path" subsection under Step 5. Include the
   exact halt comment template with the dedup marker.
4. Add the dedup pre-check snippet at the top of the halt path
   (mirroring Step 6's existing dedup pattern).
5. Update the "Red Flags / When to Stop" section.
6. Update the top-of-file checklist to reflect the new Step 5
   structure.
7. Read the updated SKILL.md end-to-end. Verify: the three buckets
   are unambiguous, the halt path is reachable, the terminal
   contract enumerates exactly four legal final actions and no
   path produces an illegal terminal summary.

### Acceptance criteria

- `skills/prepare-for-review/SKILL.md` describes a three-bucket
  finding classification in Step 5.
- The "Halt path" subsection specifies the four-step mechanics
  (file follow-up, set blocked-by, post halt comment, exit clean).
- The halt comment template is verbatim in the SKILL.md, with the
  distinct revision-footer marker.
- The halt-path dedup snippet is present and uses
  `halt path for revision \`<SHA>\`` as its marker.
- The "Terminal action contract" enumerates legal final actions
  1–4, with the halt path as #4.
- The top-of-file checklist reflects the bucket split and the
  halt-path sub-checklist entry.
- The "Red Flags / When to Stop" section clarifies that the halt
  path is a legitimate exit, not a precondition failure.

The work is done when an autonomous session reading SKILL.md can,
without further human input:

- Classify a codex finding into one of the three buckets.
- Engage the halt path correctly when bucket 3 fires.
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
