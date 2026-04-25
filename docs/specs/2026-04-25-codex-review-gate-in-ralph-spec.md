# Add codex review gate to `/ralph-spec` before Linear finalization

**Linear:** ENG-252
**Date:** 2026-04-25

## Goal

Insert a codex review gate into `/ralph-spec`'s checklist between the
user-review step and the Linear-finalization step. The gate runs
`codex-review-gate` (standard + adversarial) scoped to this session's
spec commits, presents findings to the user, and either applies fixes
inline or loops back to the spec rewrite step. This is the last chance
to probe the spec before the autonomous implementer follows it
literally with no human in the loop.

The motivation comes from ENG-213's spec session: the operator invoked
`/codex-review-gate` manually after user review, before finalization,
and Codex caught two real defects (a P2 mechanism error in the
return-channel contract, and a High-severity adversarial finding about
a partial-state gap) that self-review and user-review had both missed.
Spec-time probing has higher ROI than implementation-time probing
because the autonomous implementer follows the spec literally — there
is no human in the implementation loop to catch what the spec gets
wrong.

## Scope

Edit one file: `skills/ralph-spec/SKILL.md`.

### Edit 1 — Insert new step 10 in the Checklist; renumber finalize → 11

The Checklist (currently lines 27–40) ends:

> 9. **User reviews written spec** — ask the user to review the spec
>    file before Linear finalization.
> 10. **Finalize the Linear issue** — see "Finalizing the Linear
>     Issue" below. Terminal state: issue description matches the
>     approved spec, state is `approved_state`, blocked-by relations
>     set.

Change to:

> 9. **User reviews written spec** — ask the user to review the spec
>    file before Linear finalization.
> 10. **Codex review gate** — invoke `codex-review-gate` scoped to
>     this session's spec commits (`--base "$SPEC_BASE_SHA"` captured
>     at the start of step 7 *immediately before writing the spec
>     file*, run inside a temporary worktree detached at
>     `SPEC_HEAD_SHA`). Present findings to the user. Apply
>     trivially-actionable findings inline (commit, recapture
>     `SPEC_HEAD_SHA`, re-run the gate); substantial edits or
>     user-judgment revisions loop back to step 7 (re-trigger
>     self-review + user review before re-running the gate). See the
>     "Codex review gate" subsection below. Skip only when re-running
>     on an Approved issue and the diff since prior approval is
>     purely cosmetic.
> 11. **Finalize the Linear issue** — see "Finalizing the Linear
>     Issue" below. Terminal state: issue description matches the
>     approved spec, state is `approved_state`, blocked-by relations
>     set.

### Edit 2 — Update three forward references "step 10" → "step 11"

Three places in the file currently say "step 10" referring to the
finalize step. After Edit 1, all three become "step 11":

| Pre-edit line | Pre-edit phrase                            | Post-edit phrase                            |
|---------------|--------------------------------------------|---------------------------------------------|
| 31            | `it will be created in step 10`            | `it will be created in step 11`             |
| 36            | `for `blocked-by` relations in step 10`    | `for `blocked-by` relations in step 11`     |
| 85            | `become `blocked-by` edges in step 10`     | `become `blocked-by` edges in step 11`      |

ENG-252's description names lines 31 and 36 only — line 85 is a
third reference and must also update.

### Edit 3 — Add the Codex node and edges to the Process Flow dot graph

Add this node declaration (in the node-declaration block near the top
of the `digraph ralph_spec { ... }` body):

```
"Codex review gate\n(standard + adversarial)" [shape=diamond];
```

In the edges block, replace this single edge:

```
"User reviews spec?" -> "Finalize Linear issue\n(description + state + blockers)" [label="approved"];
```

with these three edges:

```
"User reviews spec?" -> "Codex review gate\n(standard + adversarial)" [label="approved"];
"Codex review gate\n(standard + adversarial)" -> "Write design doc\ndocs/specs/<topic>.md" [label="substantial findings"];
"Codex review gate\n(standard + adversarial)" -> "Codex review gate\n(standard + adversarial)" [label="minor fixes inline\n(commit, recapture SPEC_HEAD_SHA, re-run)"];
"Codex review gate\n(standard + adversarial)" -> "Finalize Linear issue\n(description + state + blockers)" [label="clean"];
```

The self-loop is intentional: minor fixes do not exit the gate. Every
fix-inline path commits, recaptures `SPEC_HEAD_SHA`, and re-runs the
gate. Only a clean run (no actionable findings) reaches Finalize.

The other existing edge (`"User reviews spec?" -> "Write design
doc\ndocs/specs/<topic>.md" [label="changes requested"]`) stays
unchanged.

### Edit 4 — Capture `SPEC_BASE_SHA` and `SPEC_HEAD_SHA` in the Documentation subsection

Modify the **Documentation:** subsection (currently lines 117–123) to
bracket the spec commit with SHA captures. The new bullet list:

```markdown
**Documentation:**

- **Capture pre-spec HEAD — immediately before writing the spec file, after any pre-spec sync/rebase:** `SPEC_BASE_SHA=$(git rev-parse HEAD)`. Used as `--base` for the codex gate (step 10). **Do not capture earlier in the session.** Operators commonly commit specs to `main`; any concurrent session's commits that land between this capture and the spec commit become parents of the spec commit and contaminate codex's diff. Capturing at the last possible moment narrows that window to the fraction of a second between `git rev-parse HEAD` and `git commit`. For fully-isolated review (zero parent-contamination window), commit specs on a per-session feature branch — see the "Run the gate in an isolated worktree" sub-step below for what the worktree pattern does and does not isolate.
- Write the validated design (spec) to `docs/specs/<topic>.md`.
  - Pick `<topic>` as a short kebab-case summary of what's being built.
  - If the file already exists, stop and ask before overwriting — it may belong to a related but distinct scope.
- Use `elements-of-style:writing-clearly-and-concisely` if available.
- Commit the design document to git.
- **Capture post-commit HEAD:** `SPEC_HEAD_SHA=$(git rev-parse HEAD)`. Codex runs in a temporary worktree detached at this SHA, so the review is bounded to this session's spec commits regardless of where the live HEAD moves before the gate fires.
- On loop-back from a substantial codex finding, **rewrite the spec doc, commit anew, and re-capture `SPEC_HEAD_SHA`**. `SPEC_BASE_SHA` does **not** change across loops.
```

### Edit 5 — Add a "Codex review gate" subsection in "After the Design"

Insert a new subsection immediately after the **User review gate**
subsection (currently ends around line 142) and before the
`## Finalizing the Linear Issue` heading. The subsection MUST contain
these seven elements in this order:

#### 1. Purpose paragraph

One short paragraph explaining: the autonomous implementer follows the
spec literally with no human in the loop, so spec-time codex probing is
the last chance to catch mechanism-level defects. Adversarial probing
of user-approved decisions IS the value — no escape hatch is added for
findings that contradict prior dialogue. Present findings to the user
honestly; the user decides whether to revise or keep the original call.
A decision that survives adversarial probing is stronger than one that
was never tested.

#### 2. Detection (graceful degradation)

Exact shell to locate the codex companion script:

```bash
find ~/.claude/plugins -name 'codex-companion.mjs' -path '*/openai-codex/*/scripts/*' 2>/dev/null | head -1
```

If empty, log this exact warning verbatim and proceed to step 11:

> codex-review-gate not installed — skipping codex spec review.
> Operators relying on this gate for autonomous-safety guarantees
> should install it.

If non-empty, continue to the next sub-step.

#### 3. Run the gate in an isolated worktree

Exact shell:

```bash
WT=$(mktemp -d)
trap 'git worktree remove --force "$WT" 2>/dev/null; rm -rf "$WT"' EXIT
git worktree add --detach "$WT" "$SPEC_HEAD_SHA"
pushd "$WT" >/dev/null

node <codex-script> review --json --base "$SPEC_BASE_SHA"
node <codex-script> adversarial-review --json --base "$SPEC_BASE_SHA" "<focus text>"

popd >/dev/null
if git worktree remove "$WT"; then
  trap - EXIT
fi
```

Followed by prose explaining what the pattern actually isolates:

- **Upper-bound isolation (full):** the worktree pins HEAD to
  `SPEC_HEAD_SHA`, so codex never sees commits that landed *after*
  this session's spec commit. This is the always-worktree pattern's
  primary value — protecting the diff from later HEAD drift on a
  shared-main tree.
- **Lower-bound minimization (partial):** `--base "$SPEC_BASE_SHA"`
  pins the lower bound to the SHA captured at step 7. Concurrent
  commits landing in the sub-second window between that capture and
  this session's first spec commit will become parents of the spec
  commit and appear in `base..head`. The capture-timing rule in step
  7 narrows the window to fractions of a second, but does not
  eliminate it. For fully-isolated review, commit on a per-session
  feature branch — that's the only way to guarantee no foreign
  parents.
- **Cleanup contract:** `trap EXIT` is the safety net for
  aborted/errored runs. The explicit happy-path `git worktree remove`
  is guarded by `if ... then trap - EXIT; fi`, so a failed removal
  (e.g., codex left untracked files) leaves the trap armed and the
  fallback fires on shell exit. Without the guard, the trap would be
  cleared before removal was confirmed and the worktree could leak.

The `<codex-script>` and `<focus text>` placeholders are kept literal
in `SKILL.md` — at runtime, the model substitutes the path discovered
in sub-step 2 and either the default focus text from sub-step 4 below
or a per-spec override.

#### 4. Adversarial focus text default

Use this default focus text verbatim unless the model identifies a
more specific risk to probe:

> Probe this design for: (1) ambiguities an autonomous implementer
> would misinterpret — places where two reasonable readings produce
> different code; (2) mechanism-level claims that don't hold under
> scrutiny — interfaces, return values, side effects, error contracts
> asserted by prose; (3) missing failure modes — what happens when
> the assumed inputs/state don't hold; (4) scope creep or hidden
> coupling — does this spec quietly reach into systems it shouldn't?

Override condition: if the spec has a salient targeted risk
(concurrency, auth, data integrity, integration boundary), write
per-spec focus text naming the mechanism and failure mode per
`codex-review-gate`'s "Targeted-risk prompts" guidance. The default is
a backstop, not a ceiling.

#### 5. Three finding buckets (caller policy)

The caller (`/ralph-spec`) classifies each finding into one of three
buckets. The model classifies by default; the user may override at any
time.

1. **Trivially actionable** — clear defect, prose tightening,
   ambiguity fix that doesn't change a mechanism, contract, or scope
   boundary.
   *Action:* fix inline → commit (new commit, don't amend) →
   recapture `SPEC_HEAD_SHA` → re-run the gate.

2. **Substantial actionable** — mechanism redesign, missed failure
   mode, scope change, contract correction. The fix changes what gets
   implemented.
   *Action:* loop back to step 7 (rewrite the spec doc, new commit) →
   recapture `SPEC_HEAD_SHA` → re-run self-review (step 8) → re-ask
   user (step 9) → re-run the gate (step 10). `SPEC_BASE_SHA` stays
   the same across loops.

3. **User judgment / contradicts prior dialogue** — finding is
   ambiguous, requires a design call, or pushes back on a decision
   the user already made.
   *Action:* present to the user → user decides → apply as agreed
   (becomes bucket 1 or 2 in size). **No escape hatch** —
   adversarial probing of user-approved decisions IS the value.

When the gate runs clean (no actionable findings, no user-judgment
items pending), proceed to step 11.

#### 6. Skip criterion (re-runs only)

First-run on an issue: the gate **always** invokes codex.

Re-runs on an issue already in `$CLAUDE_PLUGIN_OPTION_APPROVED_STATE`:
the gate **may** be skipped if the diff against the previously-approved
spec is purely cosmetic (typo, formatting, prose clarification with no
change to acceptance criteria, mechanism, scope, or interface). When
in doubt, run.

#### 7. Convergence

No max-iteration count. Trust user judgment. Genuinely-out-of-scope
findings get filed as Linear follow-up issues, not crammed into this
spec.

## Verification

After the edits, all of these checks must pass:

1. `grep -nE "step 10|Step 10" skills/ralph-spec/SKILL.md` —
   every match must refer to the new Codex review gate step (the
   heading itself plus narrative cross-references like "the codex
   gate (step 10)" in Edit 4 and "re-run the gate (step 10)" in
   Edit 5). No match should reference the finalize step.

2. `grep -nE "step 11|Step 11" skills/ralph-spec/SKILL.md` →
   matches the renamed Finalize heading in the checklist and the three
   forward references (former lines 31, 36, 85).

3. `grep -nE "^[0-9]+\." skills/ralph-spec/SKILL.md | head -11` →
   exactly 11 contiguous numbered items, no gaps.

4. The Process Flow dot graph contains the new
   `"Codex review gate\n(standard + adversarial)"` diamond node and
   the three new edges. The old direct
   `"User reviews spec?" -> "Finalize Linear issue..."` edge is gone.

5. The "After the Design" section has a `**Codex review gate:**`
   subsection between the user-review subsection and
   `## Finalizing the Linear Issue`. It contains all seven elements
   listed in Edit 5, in order.

6. `SPEC_BASE_SHA` and `SPEC_HEAD_SHA` each appear at least twice
   (capture + use) in the file.

7. `grep -n "skipping codex spec review" skills/ralph-spec/SKILL.md` →
   exactly one match (the literal warning string in Edit 5 sub-step 2).

No automated test suite covers this file; verification is manual review
of the resulting `SKILL.md` for internal consistency.

## Out of scope

- `codex-review-gate` itself (e.g., adding a `--head <sha>` flag).
  This ticket only adds an invocation site; the primitive's CLI
  surface stays as-is.
- `/ralph-implement` — adding the same gate there is a separate design
  question.
- `/prepare-for-review` — already runs codex review (Step 5).
- Automating decision-tracking from Codex findings into spec updates.
  The model presents findings; the user decides.
- Pre-flight checks on `/ralph-spec` (e.g., requiring a clean working
  tree before spec write).
- Recommending or enforcing a branching workflow for `/ralph-spec`
  sessions broadly. The always-worktree pattern fully isolates the
  upper bound (post-spec HEAD drift) and narrows the lower-bound race
  to a sub-second window, which is acceptable for the shared-main-tree
  workflow most of the time. Operators wanting zero parent-
  contamination should commit specs on per-session feature branches —
  noted in the Documentation subsection but not mandated.

## Testing expectations

Documentation-only edit to a skill file. No code changes, no tests to
add or update. TDD doesn't apply.

## Prerequisites

None. The spec handles `codex-review-gate` skill absence gracefully
(skip with the verbatim warning, proceed to finalization).

## Alternatives considered

1. **Codex AFTER user review** (chosen, Edit 1). Matches the ENG-252
   description verbatim. User sees codex's raw findings → transparency.
   Adversarial probing of user-approved decisions IS the value (Key
   design point). Cost: loop-back on substantial findings re-runs
   self-review + user-review.

2. **Codex BEFORE user review.** User only ever sees
   codex-incorporated spec. Fewer iterations on average. Rejected
   because the user never sees codex's raw findings (loses
   transparency about what the adversarial pass surfaced) and probing
   of user-approved decisions is the explicit value.

3. **Codex inside the finalize step** (as a substep). Rejected.
   Finalize is supposed to be a tightly-orchestrated all-or-nothing
   mechanism; embedding back-and-forth review inside it muddles the
   contract and complicates the fail-and-loop semantics.

4. **Conditional worktree** (only when HEAD has moved past
   `SPEC_HEAD_SHA`). Rejected in favor of always-worktree (Edit 5
   sub-step 3). Reasons: simpler invariant ("codex always runs detached
   at `SPEC_HEAD_SHA`"); no TOCTOU race between HEAD check and codex
   invocation; performance and disk cost of always-worktree are
   negligible (~50ms, ~100KB on APFS).

5. **Adversarial focus text left to the model per invocation.**
   Rejected in favor of a baked-in default with override condition
   (Edit 5 sub-step 4). `codex-review-gate` explicitly warns that
   undirected adversarial prompts waste the call; a strong default
   gives consistent quality, and the override condition lets targeted
   risks get specific focus text when warranted.

6. **Refuse and require manual recovery on HEAD-divergence.**
   Rejected in favor of always-worktree auto-recovery. Manual recovery
   would put operator burden on every concurrent-session scenario; the
   worktree pattern absorbs it transparently.

## Notes

- This repo (the sensible-ralph plugin's own source tree) does not
  ship a `.ralph.json`, so the standard `/ralph-spec` finalization
  flow that sources `scope.sh` cannot run here. Linear finalization
  for ENG-252 is handled out-of-band; that's a one-time
  finalization-flow concern, not a spec-edit concern.
- ENG-252 lists "no hard prerequisites." Confirmed.
