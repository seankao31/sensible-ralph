# Remove date prefixes from doc filenames in `docs/specs/` and `docs/decisions/`

**Linear:** ENG-305
**Date:** 2026-04-28

## Goal

Several files in `docs/specs/` and `docs/decisions/` have date-prefixed
filenames (e.g. `2026-04-25-foo.md`). The repo's documentation convention is
kebab-case topic names without dates — already stated explicitly in
`CLAUDE.md` for `docs/design/` and applied tacitly (by example) for the other
two layers since at least 2026-04-26. This spec removes the date prefixes
from the existing files, fixes live cross-references, and tightens
`CLAUDE.md` so the convention is no longer tacit.

## Motivation

Two reasons:

1. **Consistency.** Most files in `docs/specs/` and `docs/decisions/` already
   follow kebab-case-no-date. The date-prefixed files are heritage from the
   first few days of the project's renaming/extraction, and now stand out as
   stylistic outliers.
2. **Closing a documentation gap.** `CLAUDE.md` codifies the convention only
   for `docs/design/`. Operators and the autonomous implementer have to
   infer the rule for specs and decisions from existing examples. Codifying
   it in CLAUDE.md eliminates the inference step and aligns the three
   doc-layer descriptions.

## Scope

### In scope

**Renames (9 files, via `git mv`):**

| Current path | New path |
|---|---|
| `docs/decisions/2026-04-25-frozen-spec-cross-refs-preserved.md` | `docs/decisions/frozen-spec-cross-refs-preserved.md` |
| `docs/decisions/2026-04-25-progress-json-event-discriminator.md` | `docs/decisions/progress-json-event-discriminator.md` |
| `docs/decisions/2026-04-26-rename-sweep-grep-word-boundary.md` | `docs/decisions/rename-sweep-grep-word-boundary.md` |
| `docs/decisions/2026-04-26-sr-prefix-shell-variable-naming.md` | `docs/decisions/sr-prefix-shell-variable-naming.md` |
| `docs/decisions/2026-04-27-base-sha-written-only-by-orchestrator.md` | `docs/decisions/base-sha-written-only-by-orchestrator.md` |
| `docs/specs/2026-04-25-close-issue-bats-harness.md` | `docs/specs/close-issue-bats-harness.md` |
| `docs/specs/2026-04-25-close-issue-stale-parent-bats.md` | `docs/specs/close-issue-stale-parent-bats.md` |
| `docs/specs/2026-04-25-codex-review-gate-in-ralph-spec.md` | `docs/specs/codex-review-gate-in-ralph-spec.md` |
| `docs/specs/2026-04-25-ralph-start-default-base-branch.md` | `docs/specs/ralph-start-default-base-branch.md` |

The invariant is that the rename is detected as `R100` in the final
diff (criterion 3 below). `git mv` is the simplest way to produce that
outcome, but `mv` followed by `git add` of both the deletion and the
addition will also yield `R100` as long as the file's content is
byte-identical across the rename. The contract is on the outcome, not
the tool — `git mv` is recommended as the cleanest path.

**Live cross-reference updates in `docs/design/orchestrator.md`** — two
occurrences, both pointing at
`docs/decisions/2026-04-25-progress-json-event-discriminator.md` (one
inline cross-ref in the schema description, one bullet under "See also").
Locate by substring rather than line number — line numbers may shift
between spec time and implementation time:

```diff
-See `docs/decisions/2026-04-25-progress-json-event-discriminator.md` for the alternatives considered.
+See `docs/decisions/progress-json-event-discriminator.md` for the alternatives considered.
```

```diff
-- `docs/decisions/2026-04-25-progress-json-event-discriminator.md` — why `event` is a discriminator field rather than a separate file or nested structure.
+- `docs/decisions/progress-json-event-discriminator.md` — why `event` is a discriminator field rather than a separate file or nested structure.
```

**`CLAUDE.md` "Documentation layers" section** — the project-root
`CLAUDE.md` (`<repo-root>/CLAUDE.md`), not `~/.claude/CLAUDE.md`. Extend the
kebab-case-no-date phrasing currently scoped to `docs/design/` so it
covers all three layers. Add the bolded sentence to each of the
`docs/specs/` and `docs/decisions/` paragraphs:

```diff
 - **`docs/specs/`** — per-ticket implementation specs. Written by
   `/sr-spec`, scoped to a single Linear issue, frozen on completion.
   Mostly implementation context and detail; not a project-design
-  reference.
+  reference. Filenames are kebab-case topic names, no date prefix.

 - **`docs/decisions/`** — captured non-obvious choices, atomic and
   retrospective. Decisions accumulate here until enough related ones
   exist to synthesize into a design doc; once synthesized, the decision
   moves to `docs/archive/decisions/`. Decisions that don't relate to
   any subsystem (one-off tactical choices) just get archived directly
-  on completion.
+  on completion. Filenames are kebab-case topic names, no date prefix.
```

The `docs/design/` paragraph already states "kebab-case topic name, no date
or Linear issue header" and is left as-is.

### Out of scope

- **Inline file metadata.** Several of the affected files have inline
  `**Date:** YYYY-MM-DD` metadata or YAML frontmatter `date:` fields. These
  are part of the file's contents, not its filename. The acceptance criteria
  here are filename-only, and archived decisions in `docs/archive/decisions/`
  also keep inline date metadata — that practice continues.
- **Historical-narrative cross-references in frozen specs.** Two frozen
  specs contain date-prefixed filenames in narrative contexts that must
  stay verbatim:
  - `docs/specs/rename-to-sensible-ralph.md` — "Spec filenames containing
    `ralph`" carve-out (currently around lines 220-223), whose explicit
    purpose is to record what the rename ticket did NOT touch.
  - `docs/specs/persistent-design-doc-layer.md` — uses
    `2026-04-25-codex-review-gate-in-sr-spec.md` and
    `2026-04-25-scope-model.md` as **hypothetical examples** in prose
    describing what `docs/specs/` looked like at the time the docs-layer
    convention was being introduced. The first isn't even a real filename
    (it's a hypothetical name used to illustrate the pattern); the second
    is given as a counter-example of what a filename should NOT look like.
    Both serve their narrative purpose only at the historical paths they
    name. Additionally, this same frozen spec contains (under
    "### CLAUDE.md convention block") a verbatim copy of the original
    `## Documentation layers` text that was proposed for CLAUDE.md by
    ENG-278. After ENG-305 lands, the version in this frozen spec will
    no longer match the live CLAUDE.md (the frozen spec lacks the
    "no date prefix" sentence that ENG-305 adds). That divergence is
    by design — frozen specs are point-in-time records of what a
    ticket added, and CLAUDE.md is the live source of truth for the
    current convention. The same precedent that motivates this whole
    out-of-scope list applies: do not retroactively edit the frozen
    spec to make its proposed-CLAUDE.md text match the current
    CLAUDE.md.
  Per the precedent in
  `docs/decisions/2026-04-25-frozen-spec-cross-refs-preserved.md`,
  retroactive edits to historical-narrative lists falsify the historical
  claim. **Leave both files' references verbatim.** A future reader running
  `git grep '2026-04-25-codex-review-gate-in-ralph-spec'` will hit
  `rename-to-sensible-ralph.md` — that's expected and is not a
  stale-cross-ref bug.
- **`docs/archive/**`.** Already kebab-case-no-date.
- **CI / lint guardrail.** A pre-commit or CI check that enforces "no
  date-prefixed filenames in `docs/specs/` or `docs/decisions/`" was
  considered (Approach C in design dialogue). Rejected as YAGNI for this
  ticket — file a follow-up if the convention drifts again.
- **Self-references in renamed files.** None exist. (Verified by grepping
  each file for its own basename.)

## Implementation steps

Execute on the per-issue branch `eng-305-remove-date-prefixes-from-doc-filenames`
(already created by `/sr-spec`), inside the worktree at
`.worktrees/eng-305-remove-date-prefixes-from-doc-filenames`.

1. **Rename via `git mv`.** Run nine `git mv` invocations from the worktree
   root. Each command moves a single file; do not glob or batch them so
   that mistakes are localized. The renames are independent — order does
   not matter.
2. **Update live cross-refs in `docs/design/orchestrator.md`.** Apply the
   two diffs above. Use `Edit` (or `sed` if you prefer); the change is a
   straight string substitution of
   `2026-04-25-progress-json-event-discriminator` →
   `progress-json-event-discriminator` on those two lines only.
3. **Tighten `CLAUDE.md`.** Apply the diff above to the project-root
   `CLAUDE.md` "Documentation layers" section.
4. **Commit on the issue branch.** Single commit covering renames +
   `docs/design/orchestrator.md` updates + `CLAUDE.md` update. Use
   conventional-commits format with `Ref: ENG-305` trailer.

## Acceptance criteria

All three must hold simultaneously after the work commit lands on the issue
branch:

1. **No date-prefixed filenames remain in the in-scope directories.**
   `git ls-files docs/specs docs/decisions | grep -E '^docs/(specs|decisions)/[0-9]{4}-'`
   returns no matches and exits with status 1.

2. **The orchestrator.md cross-refs were rewritten to the correct new
   path, and no stale references to the 9 renamed files survive
   anywhere except the carve-outs.** Three checks — two positive, one
   negative — all scoped to the 9 specific basenames this ticket
   renames.

   - *Positive (new file resolves):* the new file exists at the
     expected path after rename.
     `test -f docs/decisions/progress-json-event-discriminator.md`
     exits with status 0.
   - *Positive (the orchestrator.md refs were rewritten):* the old
     basename appears nowhere in `docs/design/orchestrator.md` and the
     new basename appears at least once.
     `grep -cF '2026-04-25-progress-json-event-discriminator' docs/design/orchestrator.md`
     prints `0`.
     `grep -cF 'progress-json-event-discriminator.md' docs/design/orchestrator.md`
     prints a number ≥ 2 (the rewritten count of the originally-paired
     references; today that's exactly 2, and the implementer's diff
     shouldn't add or remove any so it should remain 2 — but the
     criterion accepts ≥ 2 to avoid a false failure if a legitimate
     third reference is added by a different ticket landing on the
     branch).
   - *Negative (no stale references to the 9 specific renamed
     basenames outside the carve-outs):* For each old basename in the
     rename table, run `grep -rIln -F "<old-basename>" .` (excluding
     `.git/` and `.worktrees/`). The matches must be a subset of:
     - `docs/specs/remove-date-prefixes-from-doc-filenames.md` — this
       spec quotes all 9 old paths in its rename table by design.
     - `docs/specs/rename-to-sensible-ralph.md` — frozen-spec
       carve-out (matches 2 of the 9 basenames per "Out of scope"
       above).
     - Any file under `docs/archive/**` — point-in-time records (none
       expected to match the 9 specific basenames today, but allowed
       if a future archived doc happens to reference one).

     Any match outside this allowlist is a stale reference that
     escaped the rename — fix it before marking the work complete.

   Note: a broader `[0-9]{4}-` pattern grep is intentionally *not* an
   acceptance criterion. This ticket renames only the 9 files in the
   table. Other files contain dated references to **different**
   historical artifacts — a deleted `docs/plans/` tree, chezmoi-repo
   paths from before the plugin was extracted, an archived recon
   note. Those references are out of scope: this ticket is not a
   sweep of every dated reference in the repo.

3. **The work commit's diff over the relevant paths is exactly what
   the spec describes, including rename detection.** Run, scoped to
   only the paths this ticket touches (so unrelated branch state — if
   any — can't poison the check):

   ```sh
   git diff --name-status -M <spec-tip>..HEAD -- \
     'docs/specs/' 'docs/decisions/' 'docs/design/orchestrator.md' \
     'CLAUDE.md' \
     ':!docs/specs/remove-date-prefixes-from-doc-filenames.md'
   ```

   …where `<spec-tip>` is the most recent `/sr-spec` commit (visible at
   the tip of the branch when `/sr-implement` starts). The output must
   contain exactly 11 lines, in any order:
   - 9 lines, each beginning with `R100<TAB><old-path><TAB><new-path>`
     — one per rename in the table above. The `R100` rename score
     requires the renamed file's content to be byte-identical across
     the rename, which is the case here (none of the renamed files'
     content changes).
   - 1 line `M<TAB>docs/design/orchestrator.md` — the cross-ref fix.
   - 1 line `M<TAB>CLAUDE.md` — the doc-layer convention tightening.

   No other lines in the output. The pathspecs above narrow the diff to
   the paths this ticket is responsible for, so the criterion is robust
   to other commits the implementer or codex iteration may add to the
   branch (e.g., spec doc fixes, which are excluded by the
   `':!docs/specs/remove-date-prefixes-from-doc-filenames.md'` exclusion).

No bats coverage is added — there are no tests for doc filenames in the
repo today, and the three acceptance criteria above cover the
deliverables of this ticket: that the 9 renames produced rename
detection, that the live cross-refs in `docs/design/orchestrator.md`
point at the new path, and that no stale references to the 9 specific
old basenames survive outside the carve-outs.

## Reasoning

**Why a single commit, not three.** The three concrete changes (renames,
live cross-ref fix, `CLAUDE.md` tightening) all express a single
conceptual edit: "the kebab-case-no-date convention now applies uniformly
to all three doc layers." Splitting them into separate commits would
fragment what `git log` shows for this conceptual change without making
review easier — the diff is small (9 renames + 4 modified lines + 2
CLAUDE.md sentences). Per `CLAUDE.md` "Unit of Work", code/docs/comment
changes for the same conceptual edit land together.

**Why leave `rename-to-sensible-ralph.md` untouched.** The file is a
frozen spec for ENG-276. Two of the renamed filenames appear in its
"Spec filenames containing `ralph`" section, which explicitly states "the
spec *files* are point-in-time records — keep the filenames as-is." The
text is documenting what ENG-276 did and didn't do at the time. ENG-305
is a *different* ticket renaming the same files for a different reason
(no-date convention, not "ralph"-token rename). Updating the frozen spec
retroactively would conflate the two tickets — a reader would see paths
that didn't exist at the time of the rename ticket and lose the
historical meaning of the carve-out. This precedent is established in
`docs/decisions/2026-04-25-frozen-spec-cross-refs-preserved.md`, which is
itself one of the files being renamed in this ticket — leaving its own
historical references untouched is consistent with the principle.

**Why recommend `git mv` over `mv` + `git add`.** Both produce the
`R100` rename detection that criterion 3 verifies, so the contract
holds either way. `git mv` is recommended because it's a single
command that keeps the working tree consistent at every step — the
old path is removed and the new path is staged in the same operation.
With `mv` + `git add`, the implementer has to remember to `git add`
both the deletion and the addition; forgetting one half leaves a
partial commit that fails criterion 3. The renamed files are
foundational context documents that get hit by `git blame` and
`git log --follow` regularly, so the rename trail matters — but `R100`
detection (which both paths produce) is what preserves the trail, not
which command produced it.

## Prerequisites

None. No `blocked-by` Linear relations needed. The work touches only
`docs/` and `CLAUDE.md`; no callable surfaces, no other in-flight ticket
needs to land first.

## Estimate

2 points. Mechanical rename + small text edit + one CLAUDE.md sentence on
each of two doc-layer descriptions. Most of the work is verification.
