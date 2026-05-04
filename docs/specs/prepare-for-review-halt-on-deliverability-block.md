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

**Scope is defined at file granularity.** The "touched code" set is
the file paths returned by
`git diff --name-only $BASE_SHA..HEAD` in the ticket's branch.
Region-level distinctions (which lines of `foo.ts` were touched vs
which weren't) are explicitly out of scope for this rule. File
granularity is what the implementer can compute with one shell
command; region-level scoping requires per-file diff parsing the
agent would have to do per finding, with little practical
correctness gain.

The agent's classification rule, applied in this strict order
(first match wins):

1. **Does the root-cause fix lie *entirely* within files in the
   touched-code set?** That is, would all required modifications to
   make the feature meet its acceptance criteria edit only files
   already in `git diff --name-only $BASE_SHA..HEAD`? If yes —
   bucket 1 (fix inline; the active spec covers these files by the
   user-global CLAUDE.md "current task's scope" definition).
2. **Else, does the finding invalidate the feature's acceptance
   criteria?** I.e. would a reviewer reading the issue description
   conclude the feature does not deliver what was promised? If yes —
   bucket 3 (halt).
3. **Else** — bucket 2 (advisory: design tradeoff, stylistic concern,
   deferred consideration, non-blocking edge case; capture in
   summary, proceed).

The "*entirely*" qualifier in step 1 is load-bearing for mixed-scope
findings. A finding can manifest in a touched file (an in-ticket
test fails, an in-ticket wrapper exposes the bug) while the actual
fix requires editing an *additional* file the ticket did not touch
(a shared helper outside the touched set). In that mixed case,
**the finding is bucket 3, not bucket 1**, because some required
edit lands outside the touched-code set. Rationale: a fix that
lands partly out-of-ticket cannot honestly be called "in scope,"
and silently editing the shared helper in a ticket's branch hides
cross-cutting changes from the reviewer.

The same-file caveat: if a finding requires editing a different
*region* of a file the ticket already touched (e.g., the ticket
modified one function in `foo.ts` and the bug is in another
function in the same `foo.ts`), the file is in the touched set, so
step 1 says bucket 1. This is intentional. A ticket's branch
"owns" the files it touches at the file-path level, and editing
another region of the same file is a normal in-ticket operation.
If the ticket genuinely should not be touching that file at all,
that's a different problem the reviewer can flag at PR time.

The simplest implementer test: write down, in one sentence, the
file paths the fix has to edit. If any of those paths is NOT in
`git diff $BASE_SHA..HEAD --name-only`, the answer is bucket 3.

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

Each bucket-3 finding gets a stable provenance key. The key MUST be
deterministic for the same finding and MUST distinguish two findings
that report different problems even when the codex review's
free-form `body` text happens to be similar. The key is constructed
from a canonical tuple of identity-bearing fields, not from `body`
alone:

```bash
# Codex's review JSON exposes title, file, line_start, line_end, body,
# and (when present) a stable rule/category id. The canonical tuple
# always includes a body component as a tail, so the key remains
# distinguishing even when all metadata fields are absent. Body is
# normalized (whitespace collapsed, leading/trailing whitespace
# trimmed) before hashing so trivial reformatting doesn't change the
# key.
FINDING_BODY_NORMALIZED=$(printf '%s' "$FINDING_BODY" \
  | tr -s '[:space:]' ' ' \
  | sed -e 's/^ *//' -e 's/ *$//')
CANONICAL=$(printf '%s|%s|%s|%s|%s|%s' \
  "${FINDING_FILE:-_}" \
  "${FINDING_LINE_START:-_}" \
  "${FINDING_LINE_END:-_}" \
  "${FINDING_RULE_ID:-_}" \
  "${FINDING_TITLE:-_}" \
  "$FINDING_BODY_NORMALIZED")
FINDING_KEY=$(printf '%s' "$CANONICAL" | shasum -a 256 | cut -c1-16)
PROVENANCE_TAG="<!-- halt-finding: ${ISSUE_ID}/${FINDING_KEY} -->"
```

`$ISSUE_ID` is the parent (the ticket prepare-for-review is running
on); `$FINDING_KEY` is the per-finding hash over the canonical tuple.
The 16-hex truncation gives 64 bits of collision resistance — ample
for the per-issue scale (single-digit findings).

The body is the *tail* of the canonical tuple, not a fallback. When
metadata fields (file, line, rule, title) are populated they
disambiguate the key cheaply; when they're absent and the
placeholders match across findings, the body component still
distinguishes independent findings. There is no separate fallback
branch — the same hash construction handles both metadata-rich and
metadata-thin findings. The single algorithm makes the snippet and
the prose describe one thing.

`$PROVENANCE_TAG` is embedded in the follow-up's description (Linear
renders HTML comments invisibly, per a known Linear behavior — but
this spec only relies on the substring being searchable, not
invisible. If Linear ever renders the tag literally, the key is still
searchable; UX degrades but correctness holds).

Why include metadata at all if the body is always present: codex
review formats often emit similar prose for similar bug patterns at
different files/lines/rules, and the metadata fields disambiguate
those near-collisions cleanly. The body-only hash worked for
metadata-thin findings but risked collapsing two distinct findings
with identical-but-applied-elsewhere bodies; the combined-tuple
hash holds in both regimes.

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
   the loop above; the relation add is idempotent on Linear).
3. **Post the halt-specific comment** (template below) via
   `linear issue comment add --body-file` from a `mktemp`
   tempfile. The halt comment has its own SHA-anchored dedup
   (see "Dedup compatibility" below): on retry, if the halt
   comment for the current HEAD is already posted, the dedup
   gate skips *the post itself* but the halt path continues to
   step 4. The dedup never short-circuits the path's exit.
4. **Undo a stale `In Review` post-state, if present.** Read the
   issue's current state. If — and *only if* — it is
   `$CLAUDE_PLUGIN_OPTION_REVIEW_STATE`, transition it back to
   `In Progress`:
   ```bash
   current_state=$(linear issue view "$ISSUE_ID" --json | jq -r '.state.name')
   if [ "$current_state" = "$CLAUDE_PLUGIN_OPTION_REVIEW_STATE" ]; then
     linear issue update "$ISSUE_ID" --state "$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE"
   fi
   ```
   This step exists for one specific case: the halt path fires from
   a re-run of `/prepare-for-review` after the *prior* run had
   already transitioned the issue to `In Review` (e.g., user demoted
   bucket-3 findings interactively in the prior run, then changed
   their mind in this run; or codex review surfaces new findings on
   a re-invocation at the same SHA). Without this undo, the
   orchestrator's post-dispatch state read would see `In Review`
   and classify the run as `in_review` (success), defeating the
   halt mechanism.

   The guard is narrow on purpose: only `In Review` is undone. If
   an operator manually moved the issue to a different state
   (`Canceled`, `Done`, a custom holding state, etc.) between the
   two runs, the halt path leaves it alone — operator state wins.
   The orchestrator's classification will then read whatever state
   the operator chose; outside of `In Review`, the
   `exit_clean_no_review` outcome won't fire, but the halt comment
   and follow-ups have still been recorded for the operator to see.
   In the common case (Step 5 firing during a first-run
   prepare-for-review where Step 7 has not run yet) the read shows
   `In Progress` and the conditional skips entirely.
5. **Exit clean** with exit code 0. Do NOT run the regular
   Step 6 (handoff comment) or Step 7 (state transition). The
   issue's post-state depends on what the conditional in step 4
   found:
   - If the read showed `In Review` → step 4 wrote
     `In Progress`. Orchestrator classifies as
     `exit_clean_no_review` (the intended outcome).
   - If the read showed `In Progress` → step 4 was a no-op.
     Orchestrator still classifies as `exit_clean_no_review`.
   - If the read showed any other state (operator manually moved
     to `Canceled`/`Done`/holding state between runs) → step 4
     was a no-op, the operator's state is preserved, and the
     orchestrator's classification follows from that state per
     `docs/design/outcome-model.md` rather than necessarily
     reading as `exit_clean_no_review`. The halt comment and
     follow-up issues have been recorded regardless, so the
     operator still sees the halt context on the issue.

The halt path is the skill's terminal path for this invocation. Per
the existing "Terminal action contract" section, the skill's last
operation must be a tool call (typically the halt comment post or
the `In Progress` restore; on a fully-reconciled retry where step
3's dedup hits and step 4's read shows the issue already in
`In Progress`, the terminal tool call is the state read itself),
not a markdown summary.

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

Halt-path dedup snippet (run *inside* halt path step 3, gating only
the post; never exits the halt path):

```bash
HALT_MARKER=$(printf 'Posted by `/prepare-for-review` halt path for revision `%s`' "$CURRENT_SHA")
HALT_ALREADY_POSTED=$(linear api 'query($issueId: String!, $marker: String!) { issue(id: $issueId) { comments(filter: { body: { contains: $marker } }, first: 1) { nodes { id } } } }' \
  --variable "issueId=$ISSUE_ID" \
  --variable "marker=$HALT_MARKER" 2>/dev/null \
  | jq '((.data.issue.comments.nodes) // []) | length > 0')
if [ "$HALT_ALREADY_POSTED" = "true" ]; then
  echo "halt comment for $CURRENT_SHA already posted; skipping repost" >&2
  # Fall through to step 4. Do NOT exit — see below.
else
  linear issue comment add "$ISSUE_ID" --body-file "$COMMENT_FILE"
fi
```

The halt-path dedup gates the *comment post* only. It MUST NOT
short-circuit the halt path's exit. The state-restore step (step 4)
must run on every halt-path execution, including retries where the
halt comment was already posted in a prior run that died before
step 4 ran. An early `exit 0` here would skip step 4, leaving the
issue in whatever state the prior partial-failure left it in
(potentially `In Review` from a regular Step 7 that fired before
the halt was decided), and the orchestrator's post-dispatch state
read would misclassify the run as `in_review` (success).

The two markers are disjoint: `Posted by /prepare-for-review for
revision <SHA>` (regular) vs `Posted by /prepare-for-review halt path
for revision <SHA>` (halt). Neither is a substring of the other, so
each dedup query matches exactly one comment type.

#### Same-SHA path transition behavior

With disjoint markers AND the halt path's state-restore step
(execution-order step 4), the dedup interaction is well-defined
for the case where the same SHA sees both decisions across
separate invocations:

- **Run A at SHA X posts a regular handoff comment and transitions
  the issue to `In Review`** (e.g., user demoted bucket-3 findings
  interactively, full normal Step 6/Step 7 path): `REGULAR_MARKER`
  matches on retry of Step 6. `HALT_MARKER` does NOT match. Issue
  state is `In Review`.
- **Run B at SHA X engages the halt path**: `HALT_MARKER` does not
  match the regular comment, so the halt path proceeds, posts the
  halt comment, then runs the state-restore step. The state read
  shows `In Review`, so the conditional write transitions back to
  `In Progress`. The issue now carries both comments and is in
  `In Progress`. Operator sees the halt comment as the most
  recent. The orchestrator's post-dispatch state read sees
  `In Progress` and classifies the run as `exit_clean_no_review`.
- **Run B's earlier reconcile-or-create loop** finds the previously
  filed follow-ups (by provenance key) — even if Run A had filed
  none (because A demoted to advisory), Run B's loop creates them
  cleanly.
- **Run C at SHA X is another retry of the halt path**:
  `HALT_MARKER` matches → step 3 skips repost. Step 4's state
  read shows `In Progress` (Run B already restored), so step 4's
  conditional write is also skipped. Exit clean. The reconcile
  loop's existing-issue check finds the already-filed follow-ups
  and no-ops.

The transition from advisory to halt at the same SHA is allowed,
recorded by both comments existing on the issue, and the
post-state contract holds because of the explicit state restore.
The reverse transition (halt → advisory at same SHA) is not
supported in autonomous mode, because once the halt path has filed
follow-ups and posted the halt comment, the run is terminal. In
interactive mode, if the user changes their mind after a halt
comment was posted, manual cleanup is required (delete the halt
comment, cancel the follow-up issues, remove the blocked-by
relations) — this spec considers that flow out of scope; file
separately if it becomes a real workflow.

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

> 4. **Halt path** — the full sequence of: reconcile-or-create
>    follow-up Linear issues with provenance keys, idempotent
>    `linear issue relation add ... blocked-by` writes, halt
>    comment post (`linear issue comment add`, gated by the
>    halt-marker dedup which skips the post but never exits the
>    path), and a `linear issue view` state read followed by a
>    conditional `linear issue update --state` that undoes any
>    stale `In Review` left by a prior run. The terminal tool call
>    is whichever of these runs last in the actual execution: on
>    a first-run halt that finds the issue in `In Review` from a
>    prior partial run, the terminal call is the
>    `linear issue update` write; on a first-run halt where the
>    state read shows `In Progress` (the common case), the
>    terminal call is the `linear issue view` read; on a halt-
>    comment-already-posted retry where the state is also already
>    `In Progress`, the terminal call is still the `linear issue
>    view` read. In all cases the issue ends up in
>    `$CLAUDE_PLUGIN_OPTION_IN_PROGRESS_STATE` *or* in whatever
>    operator-set state the halt path declines to override (see
>    halt-path execution-order step 4 for the narrow guard). The
>    orchestrator classifies the run as `exit_clean_no_review`
>    when the post-state is `In Progress` and applies
>    `ralph-failed`; that label is the operator triage signal,
>    consistent with the existing classification in
>    `docs/design/outcome-model.md`.

The illegal-final-action rule is unchanged: a markdown summary as
the session's last output is still illegal, including in the halt
path. The terminal tool call in the halt path is whichever of the
sequence above ran last for that invocation, never a text
summary.

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
> terminal tool call is whichever of comment-post / state-read /
> state-update ran last for the invocation (see "Terminal action
> contract update"). Exit code is 0. The orchestrator's
> post-dispatch state read typically sees the issue in
> `In Progress` and classifies the run as `exit_clean_no_review` —
> same operator triage path as a hard failure, but reached
> deliberately. If an operator manually moved the issue to a state
> other than `In Review` between runs, the halt path preserves
> that state (step 4 is `In Review`-only) and the classification
> follows from whatever state the operator chose.

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
   - The provenance-key construction over the canonical tuple
     `file | line_start | line_end | rule_id | title |
     normalized_body` (the body component is mandatory, not a
     fallback — see "Provenance key" in this spec).
   - The reconcile-or-create algorithm (issues + relations; the
     relation half is unconditional because `relation add` is
     idempotent on Linear).
   - The halt comment template with `HALT_MARKER`.
   - The halt-path dedup gate that skips the post on retry but
     does NOT exit the halt path (step 4 must always run).
   - The `In Review`-only post-state undo (conditional write,
     narrow guard so operator state on other transitions is
     preserved).
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
  - The per-finding provenance-key construction over a canonical
    tuple `file | line_start | line_end | rule_id | title |
    normalized_body`, 16-hex truncated SHA-256. Body is
    mandatory in the tuple, not an optional fallback.
  - The reconcile-or-create algorithm for follow-up issues, and
    unconditional idempotent `blocked-by` relation add.
  - The five-step execution order (reconcile-or-create issues,
    add relations, post halt comment with dedup gate that does
    NOT exit, undo `In Review` post-state if present, exit clean).
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
- **Concurrent-retry safety** of the reconcile-or-create loop. The
  spec assumes single-flight execution: one `/prepare-for-review`
  invocation per issue at a time. The orchestrator processes its
  queue serially (per `docs/design/orchestrator.md`), so two
  autonomous dispatches against the same issue cannot race. The
  user manually invoking `/prepare-for-review` twice in parallel
  on the same issue is not a known failure mode in this workspace,
  and adding a server-enforced uniqueness mechanism (a Linear-side
  lock or atomic check-and-create) is out of proportion to the
  exposure. If concurrent re-entry becomes a real failure mode
  later, file separately and revisit.

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
