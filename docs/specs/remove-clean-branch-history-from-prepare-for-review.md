# Remove `clean-branch-history` from `/prepare-for-review`

**Linear:** ENG-234
**Date:** 2026-04-24

## Goal

Remove the `clean-branch-history` invocation from the `/prepare-for-review`
skill. Clean linear commit history on feature branches is nice-to-have, not
must-have — the codex review, Linear handoff comment, and state transitions
all work fine on messy history. The extra step adds friction and time to
every ralph handoff for low ROI.

This reverses the workflow portion of ENG-204, which added the invocation.
The `clean-branch-history` skill itself stays available for manual
invocation; ENG-217 (Done) made it trunk-portable, so that investment is
still useful.

## Scope

Edit exactly one file: `skills/prepare-for-review/SKILL.md`.

### Edit 1 — delete Step 4 "Clean branch history"

Delete the `### Step 4: Clean branch history` section in its entirety:
the heading and the two rationale paragraphs that follow it. Normal
markdown spacing (one blank line between sections) between the
preceding and following sections is preserved.

Also update the Companion skills section:

- Remove the `clean-branch-history — folds fixups into logical commits (Step 4)` line.
- Change "Steps 1-5 expect the following skills to be installed and discoverable"
  → "Steps 1, 2, 3, and 5 expect the following skills to be installed and discoverable".

### Edit 2 — promote Step 3.5 → Step 4

The current "Step 3.5: Commit doc/decisions changes" step moves up to
"Step 4" to fill the gap. This keeps Steps 5, 6, and 7 numbered the same
as today — only Step 3.5 shifts, which minimizes the diff and avoids
touching downstream cross-references.

Rename "Step 3.5" to "Step 4" in four places:

1. The step heading itself:
   `### Step 3.5: Commit doc/decisions changes`
   → `### Step 4: Commit doc/decisions changes`

2. Pre-flight "`??` lines" note:
   "because Step 3.5 stages all new untracked files"
   → "because Step 4 stages all new untracked files"

3. Pre-flight "Once the working tree is clean" sentence:
   "safe to stage in Step 3.5"
   → "safe to stage in Step 4"

4. Step 2 commits note:
   "one from Step 2, one from Step 3.5 covering prune changes"
   → "one from Step 2, one from Step 4 covering prune changes"

### Edit 3 — update Step 4 (was 3.5) rationale

The rationale sentence currently references both Step 4 and Step 5:

> Steps 1–3 may have modified or created files. Commit them so the
> history cleanup in Step 4 and codex review in Step 5 see the complete
> branch (including docs):

After removal there's no history cleanup. Change to:

> Steps 1–3 may have modified or created files. Commit them so the codex
> review in Step 5 sees the complete branch (including docs):

### Edit 4 — update Step 5 codex scope parenthetical

The codex step currently says the review is scoped to
`(code + docs after history cleanup)`. Drop "after history cleanup":

> Invoke the `codex-review-gate` skill, passing `--base "$BASE_SHA"`
> (computed above) so the review is scoped to this branch's commits
> (code + docs).

## Cross-references that stay untouched

Fresh audit of `Step N` references in the file after the edits above.
These do not need changes and must NOT be edited:

- **"skip Step 7" / "including Step 7"** idempotency paragraphs — Step 7
  (state transition) keeps its number.
- **"used in Steps 1, 5, and 6"** in the Compute-base-SHA paragraph.
  This line currently omits Step 4 (`clean-branch-history` uses
  `--base "$BASE_SHA"` too) — so it's pre-existing slightly wrong. After
  removing Step 4, the line becomes correct as-is. Leave it.
- **"skip to Step 7"** in the Step 6 dedup check — Step 7 still exists.
- **"Capture them in Step 6's Review Summary" / "persist until Step 6"**
  in the codex ambiguous-findings guidance — Step 6 keeps its number.
- **Step 5, Step 6, Step 7 headings** — keep their current numbers.

## Out of scope

The following files/places are explicitly excluded:

- `clean-branch-history` skill — lives in chezmoi
  (`agent-config/skills/clean-branch-history/SKILL.md`), not this plugin
  repo. Stays unchanged; still callable manually.
- chezmoi `agent-config/superpowers-overrides/finishing-a-development-branch/SKILL.md`
  — the Step 1b invocation. This override is being retired in favor of
  ralph v2 (`/prepare-for-review` + `/close-feature-branch`); investing
  in it is wasted effort.
- chezmoi `agent-config/docs/specs/2026-04-22-autonomous-approval-gates-design.md`
  line 177 — parenthetical mention of `clean-branch-history` in a
  completed implementation plan (ENG-230). Historical record, not live
  guidance.
- chezmoi `agent-config/docs/playbooks/superpowers-patches.md` — documents the
  `finishing-a-development-branch` override, which isn't changing.
- chezmoi `agent-config/docs/decisions/2026-04-22-trunk-detection-block-duplication.md`
  — decision log record.
- chezmoi `agent-config/docs/specs/2026-04-24-sensible-ralph-plugin-extraction.md`
  — lists `clean-branch-history` among skills to extract to the plugin.
  Still correct: the skill moves to the plugin regardless of this change.
- Other skills in this plugin (`close-issue`, `ralph-implement`, `ralph-spec`,
  `ralph-start`) — none reference `clean-branch-history` or the step
  numbering changed here.

## Verification

After the edits, all three checks must pass:

1. `grep -n "clean-branch-history" skills/prepare-for-review/SKILL.md`
   → zero matches.

2. `grep -n "Step 3\.5\|history cleanup\|after history cleanup" skills/prepare-for-review/SKILL.md`
   → zero matches.

3. `grep -n "^### Step" skills/prepare-for-review/SKILL.md`
   → exactly seven headings: Step 1, Step 2, Step 3, Step 4, Step 5,
   Step 6, Step 7 (no gap at Step 4).

4. Visually audit that every `Step N` reference in the file (from
   `grep -n "Step [0-9]"`) points to a heading that exists after the
   edits.

No automated test suite covers this file; verification is manual review
of the resulting SKILL.md for internal consistency.

## Testing expectations

This is a documentation-only edit to a skill file. No code changes, no
tests to add or update. TDD doesn't apply.

## Prerequisites

None.

## Alternatives considered

1. **Promote Step 3.5 → Step 4, keep downstream numbering** (chosen).
   Smallest diff. Avoids touching Steps 5/6/7 or their cross-references.
   Four step-number renames (all Step 3.5 → Step 4) plus the two
   content edits (rationale and codex parenthetical).

2. **Renumber Steps 5/6/7 → 4/5/6 as well** (the ticket's original plan).
   Larger diff. Requires updating six additional cross-references
   ("skip Step 7", "including Step 7", "Steps 1, 5, and 6",
   "skip to Step 7", "Step 6's Review Summary", "persist until Step 6").
   No behavioral benefit over the chosen approach.

3. **Deprecate `clean-branch-history` entirely.** Rejected. ENG-217 just
   made it trunk-portable; killing it would waste that work, and the
   `finishing-a-development-branch` override still uses it.

4. **Make `clean-branch-history` an opt-in flag on `/prepare-for-review`.**
   Rejected. Adds complexity to the skill for no real benefit. Anyone
   who wants history cleanup can invoke the skill directly before
   running `/prepare-for-review`.

## Notes

- ENG-217 is `Done` (the ticket description says "In Review" — minor
  drift). The claim that its improvements still apply for manual
  invocation remains correct.
