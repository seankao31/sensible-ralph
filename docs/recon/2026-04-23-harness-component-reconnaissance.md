**Date:** 2026-04-23
**Linear issue:** ENG-246 (recon of harness components for ralph v2 pipeline stages)
**Relates to:** ENG-178 (ralph v2 workflow evaluation — arm lists refined by this recon)
**Status:** Pass 1 (read-level audit) complete. Pass 2 (pilot) deferred to follow-up ticket.

## Scope note

Per PRD, ENG-246 originally planned to cover Pass 1 + Pass 2 + recon doc + any triggered ADRs in one ticket. In practice, Pass 2 is explicitly "fresh worktree, fresh session per shortlisted component" — architecturally incompatible with a single autonomous ralph session. This recon ticket shipped Pass 1 + the recon doc + shortlist + ADRs; Pass 2 is filed as a follow-up. See the Ticket Structure section at the bottom.

## Method actually executed

Two-pass plan; Pass 1 only in this ticket. For each in-scope component (four layers: our in-repo skills, our superpowers overrides, upstream `obra/superpowers` non-overridden pipeline components, external repos) we recorded purpose, fit against the five dimensions below, integration cost, prompt-quality signal, and a recommendation verdict.

Dimensions:
1. **Linear-native state transitions** (approved → in progress → in review → done)
2. **Worktree-per-issue isolation**
3. **Autonomous-mode escape-hatch semantics** (exit clean with a Linear comment; no retry loops)
4. **Programmatic-grading handoff** (produces an artifact the next phase can consume without human intervention)
5. **Upstream CLAUDE.md rules** (TDD, root-cause debugging, no backcompat without approval)

Verdicts: **keep** / **adapt** / **adopt** / **drop** / **pilot**.

## Correction re: override vs upstream comparison

An initial read concluded our `superpowers-overrides/*/SKILL.md` files were byte-identical to "upstream" and therefore redundant. This was a **symlink artifact**: the plugin cache at `~/.claude/plugins/cache/claude-plugins-official/superpowers/5.0.7/skills/<name>/SKILL.md` is symlinked TO `agent-config/superpowers-overrides/<name>/SKILL.md`, so diffing them returns empty.

The authoritative comparison is against `obra/superpowers` at tag `v5.0.7` fetched from GitHub. Against actual upstream, diff sizes are:

| Override | Diff lines vs v5.0.7 upstream |
|----------|-------------------------------|
| `brainstorming` | 22 |
| `writing-plans` | 42 |
| `subagent-driven-development` | 101 |
| `using-superpowers` | 7 |
| `finishing-a-development-branch` | 93 |

All overrides remain load-bearing. The patches documented in `agent-config/docs/playbooks/superpowers-patches.md` are faithfully applied.

---

# Phase 1: idea → PRD

## Our in-repo `ralph-spec` (Phase 1 entry point)

- **Purpose.** Transform a raw idea into an Approved Linear issue (PRD) with `docs/specs/<topic>.md` and blocker relations, ready for autonomous dispatch by `ralph-start`.
- **Fit for ralph v2.**
  - Linear transitions: **yes.** Full state-machine driver (Todo/Backlog → Approved), config-driven state names.
  - Worktree isolation: **no** — interactive skill in the main checkout; spec authoring doesn't need a worktree. Not a fit issue; it's by design.
  - Autonomous-mode escape-hatch: **n/a** — explicitly scoped interactive-only with a HARD-GATE "do NOT invoke any implementation skill."
  - Programmatic-grading handoff: **yes.** Produces `docs/specs/<topic>.md` + Linear description; both are the spec contract ralph-implement consumes.
  - CLAUDE.md rules: **partial.** Enforces scope clarity + autonomous-readiness. TDD/debugging rules N/A (spec phase).
- **Integration cost.** Hard deps on `ralph-start` libs (config/Linear), `linear-workflow`, jq, Linear CLI. Optional superpowers brainstorming visual companion.
- **Prompt-quality signal.** High — prescriptive 10-step checklist, spec self-review gates (placeholder/contradiction/scope/ambiguity), prerequisite surfacing + blocker verification via PREREQS vs actual cross-check. Intrinsically hallucination-resistant.
- **Recommendation:** **keep.**
- **Justification.** Core Phase 1 component. Strong state machine, prescriptive gating, HARD-GATE prevents implementation leak-through. No blockers to evaluation.

## Our `brainstorming` override

- **Fit:** same upstream design discipline + linear-workflow insertion (step 9) threading design→issue→plan for ralph v2's Linear-driven flow.
- **Integration cost:** depends on `linear-workflow`; invokes `writing-plans` at terminal.
- **Prompt-quality:** inherits upstream rigor (anti-patterns, validation gates, visual companion).
- **Recommendation:** **keep.** Override vs upstream: **still-load-bearing** (22-line diff against v5.0.7 upstream inserts the `linear-workflow` step and process-flow node that upstream lacks).

## Upstream `brainstorming` (as baseline)

- Identical design discipline without Linear integration. Pipeline would lose the Phase 1 → Linear anchor.
- **Recommendation:** **drop-as-arm** (not competitive as Phase 1 arm against our override; baseline only).

## External: `mattpocock/skills` — `/grill-me`

- **Core technique.** Depth-first one-question-at-a-time walk of the design decision tree, with the agent offering a recommended answer per question, plus an explicit off-ramp: *if the question can be answered by exploring the codebase, explore instead.* The codebase-check-first clause is the distinctive bit.
- **Fit:** every dimension **no/none** as raw skill (pure dialogue, no Linear/worktree/escape-hatch/handoff). It's a prompt, not a harness.
- **Integration cost:** 635-byte prompt — trivial to lift. To function as a Phase 1 arm, wrap it inside the existing `ralph-spec` plumbing (Linear fetch, spec MD write, Approved transition, blocked-by). ~80% of that plumbing is ours already.
- **Prompt-quality:** high on shape, low on stop-condition rigor ("shared understanding" is subjective).
- **Recommendation:** **pilot.** Genuinely distinct shape from our brainstorming override (depth-first single-branch with recommended answer + codebase-check-first) vs our breadth-first divergent brainstorming. Worth measuring against our baseline in ENG-178 Phase 1.
- **Justification.** Low pilot cost — swap the brainstorming prompt inside `ralph-spec` wrapper; all pipeline plumbing stays ours. Do NOT adopt as-is; it lacks every pipeline dimension.

## External: `mattpocock/skills` — `to-prd` (Phase 1→2 straddler, included here)

- PRD template: Problem / Solution / User Stories / Implementation Decisions / Testing Decisions / Out of Scope. "No file paths / no code snippets, they go stale" rule.
- **Recommendation:** **adapt** — cherry-pick the explicit Testing Decisions section + "deep modules" framing into `ralph-spec`'s template if not already present. Not a pilot candidate; too close to what we have.

## External: `addyosmani/agent-skills` — `idea-refine`

- Five named divergence lenses (Inversion / Audience-shift / 10x / Simplification / Expert-lens) + "what could kill this idea?" convergence.
- **Fit.** Same-function competitor to our `brainstorming` override: both produce divergent exploration of an idea. Phase 1 is interactive (ralph-spec has humans in the loop), so `AskUserQuestion` compatibility is not a disqualifier here — our own override also uses interactive dialogue. The real comparison is shape: named-lens divergence vs breadth-first validation-gated divergence.
- **Recommendation:** **pilot** as a Phase 1 comparative arm under the same wrapping pattern as `/grill-me` (lift the skill's prompt, drive it through the `ralph-spec` harness). Second Phase 1 pilot alongside `/grill-me`. Also retain the prompt-level adoptions in Cross-cutting finding #5 for the default arm regardless of pilot outcome.

## External: `addyosmani/agent-skills` — `spec-driven-development`

- "ASSUMPTIONS I'M MAKING → correct me now" ritual, three-tier Boundaries scaffold (Always / Ask-first / Never), 4-gate human-review flow.
- **Fit.** Spec-authoring layer rather than a full Phase 1 harness (no Linear, no Approved transition, no blocked-by). The 4-gate human-review flow is not a disqualifier for Phase 1 (Phase 1 is interactive) — but the gates don't map cleanly to our single-Approved-state handoff either. Competitor to `ralph-spec`'s spec-writing step, not to the brainstorming step.
- **Recommendation:** **drop-as-component, adapt prompts** — the "ASSUMPTIONS I'M MAKING" ritual and the three-tier Boundaries scaffold (Always / Ask-first / Never) are both worth lifting into `ralph-spec`. Flagged in Cross-cutting finding #7 for Pass 2 re-evaluation under comparative-arms framing: if Phase 2 pilot results suggest the spec authoring itself is a measurable arm axis, this skill becomes a pilot candidate for that axis.

## External: `alirezarezvani/claude-skills` — `product-discovery`

- Teresa Torres Opportunity Solution Tree + assumption-mapping. Sits upstream of our pipeline (problem is already decided by the time `ralph-spec` is invoked).
- **Recommendation:** **drop.** Our entry point is later in the funnel.

## External: `frankbria/ralph-claude-code`

- No per-step components. Single-prompt loop runner with empty `specs/` + `templates/specs/`. `SPECIFICATION_WORKSHOP.md` is a human Three Amigos facilitator guide, not an agent-invokable shape.
- **Recommendation:** **drop.** Anti-aligned with our CLAUDE.md ("PRIORITIZE: Implementation > Documentation > Tests"; "LIMIT testing to ~20% of effort"). Nothing relevant.

## External: `snarktank/ralph` — `prd` skill

- Interactive PRD authoring via 3–5 lettered clarifying questions, writes `tasks/prd-[feature].md`.
- Strictly less capable than our `ralph-spec` (no Linear, no Approved transition, no blocked-by).
- **Recommendation:** **drop.** Lettered-options Q&A pattern is tactical at best, not worth integrating.

## Phase 1 summary

- **Winner for ENG-178 Phase 1 default arm:** our `brainstorming` override, threaded through `ralph-spec`. Only Phase-1 shape with Linear/autonomous-ready plumbing.
- **Pilot arms for Phase 1 comparison (ENG-178):**
  - `/grill-me` wrapped in the `ralph-spec` harness. Distinct depth-first + codebase-check-first shape.
  - `idea-refine` wrapped in the `ralph-spec` harness. Named-lens divergent shape for comparison against our breadth-first validation-gated divergence.
  - Both pilots share the same plumbing-reuse pattern; swap cost per pilot is one prompt file.
- **Cherry-pick into `ralph-spec`/brainstorming (no pilot required, stack-changing but low risk):**
  - `idea-refine`'s five named divergence lenses
  - `spec-driven-development`'s assumptions-first opening ritual + three-tier Boundaries scaffold
  - `idea-refine`'s "what could kill this idea?" convergence check
  - `to-prd`'s explicit Testing Decisions section (if not already in our template)
- **Not competitive:** `frankbria/ralph-claude-code` (loop runner, anti-aligned), `snarktank/ralph`'s `prd` (strictly weaker than ours), `product-discovery` (wrong point in funnel).

---

# Phase 2: PRD → plan

## Our `writing-plans` override

- **Fit:** upstream plan rigor (bite-sized tasks, exact file paths, TDD, no placeholders) + patches that force the fresh-session SDD+codex handoff and remove the executing-plans alternative.
- **Recommendation:** **keep.** Override vs upstream: **still-load-bearing** (42-line diff removes the two-option executing-plans branch and mandates fresh-session subagent-driven execution with codex gates).

## Upstream `writing-plans`

- Offers two-option execution handoff (subagent-driven OR executing-plans). Mentions two-stage review, not three-stage-with-codex.
- **Recommendation:** **drop-as-arm** — our override closes the door on the executing-plans alternative, which is deliberate.

## Upstream `executing-plans` (candidate Phase 3 arm, discussed here for context)

- Same-session batch execution with review checkpoints. Calls `using-git-worktrees` on entry, `finishing-a-development-branch` on exit.
- **For Phase 2:** n/a (this is a plan *executor*, not a plan *writer*).
- **For Phase 3:** see the Phase 3 section below; it is ENG-178 Phase 3 Arm A's natural alternative to SDD-style fresh-subagent-per-task execution.

## PRD-only baseline (no plan step)

- Skip `writing-plans`; feed the PRD directly to Phase 3.
- **Fit:** trivially Linear-native (no plan skill to coordinate). Worktree/escape-hatch/handoff dimensions all pass through the Phase 3 executor.
- **Integration cost:** zero new skills; removes a step.
- **Recommendation:** **pilot** (this is ENG-178 Phase 2 Arm B — the live question ENG-178 wants answered).
- **Justification.** Opus 4.7 may be able to implement from a well-written PRD without a separate plan. Measuring this is exactly the Phase 2 experiment.

## External: `addyosmani/agent-skills` — `planning-and-task-breakdown`

- Dependency-graph + vertical-slice decomposition with verification commands + per-2-3-task checkpoints.
- **Distinct mechanism from `writing-plans`:** task template specifies **acceptance criteria + verification commands + files likely touched + estimated scope**, explicitly NOT pre-written code snippets or function signatures. Contract is behavioral (did the tests pass, does it build, does the manual check work) rather than literal (did you produce the exact code dictated). Upstream `writing-plans` over-specifies at the code level — a holdover from weaker-model coordination eras — and our override does not fix that axis. Additional primitives: XL → break-down triggers ("writing 'and' in the title" heuristic), parallelization triage (safe / sequential / coordination-required), "noticed but not touching" adjacent-scope protocol.
- **Fit.** Linear-native n/a (plan-writing layer is phase-internal); worktree n/a; autonomous escape-hatch n/a at this layer; programmatic-grading-handoff partial (verification commands per task are machine-checkable); CLAUDE.md partial ("review with human before proceeding" checkpoints map to automated test+build gates in autonomous mode). Human-review checkpoints are replaceable with automated gates — same adaptation as other interactive skills.
- **Recommendation:** **pilot** as a distinct Phase 2 comparative arm. The ENG-178 Phase 2 question ("does a separate plan phase add value?") benefits from measuring against more than one plan-phase shape; acceptance-criteria-first is a materially different abstraction level from `writing-plans`'s prescriptive task-body contents.

## External: `alirezarezvani/claude-skills` — `spec-driven-workflow`

- RFC-2119-formatted requirements, Given/When/Then ACs, a `spec_validator.py --strict` score gate, bounded-autonomy escalation template with STOP conditions.
- **Fit:** Strong on **programmatic grading** — `spec_validator.py` + `test_extractor.py` give machine-checkable handoff spec → tests → code, exactly the shape our pipeline lacks. Strong on **escape hatch** — the escalation-with-recommendation template parallels our autonomous-exit-with-Linear-comment pattern.
- **Recommendation:** **adapt.** Lift two patterns: (a) a validator-script gate at Phase 1→2 boundary that programmatically checks spec completeness before ralph-implement dispatches; (b) the escalation-with-explicit-recommendation template for autonomous-mode exit comments. Don't adopt the whole skill — it conflates phases we keep separate.

## External: `snarktank/ralph` — `ralph` skill (JSON plan with pass flags)

- Converts markdown PRD to `prd.json` schema with `{project, branchName, userStories[]}`, each with `passes: false/true`.
- **Interesting design idea:** "plan = machine-checkable list with per-item pass/fail state." Maps cleanly to Linear sub-issues with state transitions.
- **Recommendation:** **adapt (idea only, not code).** Capture as an alternative Phase 2 output shape in design notes; evaluate against free-form plan.md when Phase 2 runs its own shape experiment. Not a pilot arm for ENG-178 Phase 2 (the arms there are plan-skill shape, not output-format shape).

## External: `mattpocock/skills` — `to-issues`

- PRD → tracer-bullet vertical-slice issues with HITL/AFK tagging + blocked-by chains.
- **Recommendation:** **drop.** The HITL/AFK label primitive was initially assessed as novel and ADR-worthy; on review, it adds per-ticket operator tax ("tag every issue") for marginal triage value (`/ralph-start` already skips blocked issues; Approved-but-not-truly-ready is a spec-quality gap better addressed upstream in `ralph-spec` than downstream by filtering). Not competitive as a component; no prompt-level primitives worth lifting.

## Phase 2 summary

- **Winner for ENG-178 Phase 2 default arm:** our `writing-plans` override (current default).
- **Pilot arms for Phase 2 comparison (ENG-178):**
  - PRD-only baseline (skip `writing-plans` entirely — feed PRD directly to Phase 3). Live question: does a separate plan phase add value above the Phase-1 quality bar?
  - `planning-and-task-breakdown` wrapped as a plan-writer alternative. Live question: at what abstraction level should Phase 2 tasks be written (acceptance-criteria-first vs upstream's code-specified contents)?
- **Design-note recommendation (no ADR yet):** Capture `snarktank/ralph`'s JSON-plan-with-pass-flags as alternative Phase 2 output shape; decide during Phase 2 execution.
- **Validator-gate recommendation:** Adapt `spec_validator.py`-style programmatic completeness check for the Phase 1→2 handoff. Worth a pilot.
- **Not competitive:** `snarktank/ralph`'s `prd` skill (Phase 1 tooling; evaluated under Phase 1).

---

# Phase 3: plan → code

## Our in-repo `ralph-implement`

- **Fit:**
  - Linear: **partial** — issue pre-transitioned to In Progress by orchestrator; delegates Review transition to `/prepare-for-review`.
  - Worktree: **yes** — expects pre-created worktree + `.ralph-base-sha`.
  - Escape-hatch: **yes** — explicit red flag list (missing ISSUE_ID, malformed PRD, merge conflicts, test failures, unreachable Linear CLI); declines to invoke `/prepare-for-review` on failure to signal `exit_clean_no_review`.
  - Handoff: **partial** — conditional `/prepare-for-review` invocation; downstream skill actually produces the Linear In-Review transition and comment.
  - CLAUDE.md: **yes** — mandates `test-driven-development` + `systematic-debugging`, smallest reasonable changes.
- **Prompt-quality:** moderate. Strong red-flag list + conditional gates. Implementation section is thin — delegates to external skills (TDD, debugging) without repeating critical verifications. No explicit scope-recheck after implementation; no artifact-shape checklist for handoff.
- **Gap found during audit:** does not reference upstream `superpowers:verification-before-completion`, which is the natural source of "no success claim without fresh verification" discipline at Step 4. Adopt-immediately candidate per PRD open question #2.
- **Recommendation:** **adapt.** Structurally sound; tighten Step 3 (scope adherence) and Step 4 (invoke `verification-before-completion`).

## Our `subagent-driven-development` override

- **Fit:** fresh-subagent-per-task with three-stage review (spec, quality, codex) per task + final codex. Terminates at `finishing-a-development-branch` → Linear Done. Autonomous-safety block "If final codex review finds issues: STOP, present findings, ask user" prevents blind auto-fixes.
- **Recommendation:** **keep** (core design discipline) with an **integration gap flagged for follow-up** (see below).
- **Integration gap vs ralph v2.** The SDD override's terminal step invokes `superpowers:finishing-a-development-branch`, whose current behavior is an interactive 4-option menu (merge locally / push+PR / keep / discard) with default=rebase-and-merge-to-main, followed by a direct Linear → Done transition. Ralph v2 autonomous exits pass through `/prepare-for-review` → Linear In Review and rely on a human gate (`/close-feature-branch` / `/close-issue`) for the main merge. If this SDD override is invoked under `claude -p` (e.g., ENG-178 Phase 3 Arm D), the terminal menu cannot be answered and the default action is categorically wrong for ralph (merges to main, skips the review gate). Fix tracked as **ENG-265**: patch `finishing-a-development-branch` itself to detect ralph context (`.ralph-base-sha` present) and short-circuit to `/prepare-for-review` so every skill that terminates via this handoff composes with ralph v2 without per-caller patching. This is coexistence-patching, not ongoing investment in the superseded shape.
- Autonomous-safety of the codex-findings block depends on caller-side policy added after ENG-220 made `codex-review-gate` caller-agnostic.

## Upstream `subagent-driven-development`

- Same decomposition but no per-task codex and no terminal-findings handling.
- **Recommendation:** **drop-as-arm** unless pilot proves the codex tier is marginal. Relevant arm for ENG-178 Phase 3 is Arm C (SDD minus Claude reviewers), not upstream SDD.

## Upstream `executing-plans`

- Same-session batch execution; uses `using-git-worktrees` on entry, `finishing-a-development-branch` on exit. Strong "raise concerns first" gate and explicit red-flag stopping.
- **Fit:** Linear-native partial (requires human-approval checkpoint between phases); worktree yes; escape-hatch yes; handoff partial; CLAUDE.md yes.
- **Recommendation:** **adopt-as-arm.** Natural candidate for ENG-178 Phase 3 Arm E (SDD decomposition + single-session execution). Our override's writing-plans deliberately removed this path; the experiment in ENG-178 reopens the question.

## Upstream `dispatching-parallel-agents`

- Dispatch isolated agents per independent problem domain.
- **Fit:** light/partial on most dimensions. Useful as a Phase 3 sub-pattern for test-failure triage, not as a primary arm.
- **Recommendation:** **pilot** for Phase 3 blocker triage, not Phase 3 primary arm.

## Upstream `test-driven-development`, `systematic-debugging`

- Cross-cutting. Already mandated by our CLAUDE.md; referenced by `ralph-implement`.
- **Recommendation:** **keep** (already adopted).

## Upstream `verification-before-completion`

- "No completion claim without fresh verification" — evidence before assertions.
- **Fit:** yes on every dimension except produces-artifact-for-next-phase.
- **Gap:** not currently referenced by our `ralph-implement` or any override. Per PRD open question #2, this is "adoptable-but-unused upstream we should probably use" — the answer is ADR-to-adopt.
- **Recommendation:** **adopt.** Invoke from `ralph-implement` Step 4 ("Verify tests pass") before invoking `/prepare-for-review`. Filed as its own ADR below.

## Upstream `requesting-code-review`, `receiving-code-review`

- Review-dispatch and review-response mindsets. Cross-cutting. `requesting-code-review` is referenced from our SDD override; `receiving-code-review` is unreferenced but behavioral.
- **Recommendation:** **keep.** Not pipeline arms — supporting doctrine.

## External: `frankbria/ralph-claude-code`

- Single-prompt loop runner with no per-step execution shape. `PROMPT.md` says "LIMIT testing to ~20% of effort, only write tests for NEW functionality" — directly contradicts our TDD-first rule.
- **Recommendation:** **drop.** Not competitive, anti-aligned.

## External: `addyosmani/agent-skills` — `incremental-implementation`

- Five numbered execution rules on top of thin-vertical-slice loop: **Rule 0 Simplicity First** (concrete bad/good pairs — EventBus-with-middleware vs function call, abstract factory vs two components), **Rule 0.5 Scope Discipline** with an explicit "NOTICED BUT NOT TOUCHING" protocol for adjacent-scope observations, **Rule 1** one thing per increment, **Rule 2** keep-it-compilable, **Rule 3** feature flags for incomplete features, **Rule 4** safe defaults, **Rule 5** rollback-friendly additive changes. Named slicing strategies (vertical / contract-first / risk-first). Common-rationalizations table for scope-creep.
- **Distinct mechanism vs our stack:** the "NOTICED BUT NOT TOUCHING" primitive directly addresses the same gap that triggered ADR-3 (`ralph-implement` Step 3 scope tightening) — and does so as a ready-made formulation rather than a bespoke paragraph. Named slicing strategies (risk-first in particular) give plan authors vocabulary we don't have. Feature-flag-for-incomplete and rollback-friendly rules cover mergeability cases our stack doesn't explicitly handle.
- **Recommendation:** **pilot** as an execution-discipline layer inside Phase 3 subagent prompts (SDD's implementer-prompt, upstream `executing-plans`). Independent of the Phase 3 shape arm (single-session vs SDD vs executing-plans), a different execution-discipline layer may move results. Also **partial-adopt** the NOTICED BUT NOT TOUCHING protocol and named slicing strategies into our stack independent of pilot outcome — they slot into subagent implementer prompts cheaply.

## External: `addyosmani/agent-skills` — `test-driven-development`

- Standard RED/GREEN/REFACTOR with three distinct primitives beyond upstream `superpowers:test-driven-development`: **"Prove-It Pattern"** (explicit numbered sequence for bug-fix flow: test-first repro → fix → test passes → full suite regression check), **Test Pyramid with percentages + Resource Model** (Small = single process no I/O, Medium = localhost only, Large = external services; orthogonal to unit/integration/e2e split), **"Test State, Not Interactions"** as an explicitly callout-boxed anti-pattern.
- **Recommendation:** **partial-adopt.** Lift the Prove-It Pattern as a named sequence for bug-fix flows, the Resource Model for test-sizing guidance, and the Test State Not Interactions callout into our TDD material (either our override of `test-driven-development` if we create one, or a local doctrine doc referenced from CLAUDE.md). Not a pilot candidate — TDD is cross-cutting, already mandated; specific primitive adoption is the right granularity.

## External: `alirezarezvani/claude-skills` — `karpathy-coder`

- Pre-commit gate enforcing "surface assumptions / simplicity / surgical changes / goal-driven" via detector scripts (`complexity_checker.py`, `diff_surgeon.py`, `assumption_linter.py`, `goal_verifier.py`). Reviewer sub-agent + `hooks/karpathy-gate.sh`.
- **Fit:** best external match on **upstream CLAUDE.md rules** — "surgical changes / no drive-by refactor" matches our "SMALLEST reasonable changes." Scripts are stdlib Python. No Linear/worktree/escape-hatch.
- **Recommendation:** **pilot** as a non-blocking pre-commit warning in the chezmoi repo. `diff_surgeon.py` heuristic for flagging drive-by changes is directly useful for ralph autonomous sessions that occasionally sprawl. Pilot as warning-only; decide on blocking after a few runs.

## External: `alirezarezvani/claude-skills` — `git-worktree-manager`

- Scripted worktree creation + cleanup with dirty-tree / merged-only safety checks.
- **Recommendation:** **drop.** Overlaps our existing `using-git-worktrees` + `close-branch` skills; ours are Linear-aware and already encode the merge/push invariants.

## External: `mattpocock/skills` — `tdd`

- Same red-green-refactor as upstream `test-driven-development` with one crisp callout: "horizontal slicing anti-pattern."
- **Recommendation:** **adapt.** Cherry-pick the horizontal-slicing anti-pattern callout into our TDD material.

## Phase 3 summary

- **Winner for ENG-178 Phase 3 default arm:** our `ralph-implement` + `subagent-driven-development` override (current default for SDD-shape; `ralph-implement` for single-session-shape). Note the SDD override's `finishing-a-development-branch` integration gap callout above — a follow-up ticket patches the downstream skill to be ralph-aware so Arm D actually composes with `claude -p` runs.
- **Pilot arms for Phase 3 shape comparison (ENG-178):**
  - Upstream `executing-plans` as Arm E's natural basis.
  - Upstream SDD (minus our codex-per-task patch) as Arm C's natural basis.
  - Per ENG-178, Arms A/B/D are already named and unchanged.
  - **No Arm F from this recon** — neither the meta-harness artifact (covered separately in ENG-178 OQ #2) nor any external repo surfaced a Phase 3 *shape* not already covered by Arms A–E.
- **Pilot arm for Phase 3 execution-discipline axis (orthogonal to shape):** `incremental-implementation` layered into subagent implementer prompts. This is a separate axis from the shape arms — it can be measured against the same-shape baseline to isolate the execution-discipline contribution.
- **Stack-changing recommendations (ADR candidates):**
  - Adopt `verification-before-completion` into `ralph-implement` Step 4.
  - Pilot `karpathy-coder` detectors as non-blocking pre-commit warnings.
- **Prompt-level cherry-picks:**
  - mattpocock `tdd` horizontal-slicing anti-pattern into TDD material.
  - addyosmani `test-driven-development` Prove-It Pattern, Resource Model, and Test State Not Interactions callouts into TDD material.
  - addyosmani `incremental-implementation` NOTICED BUT NOT TOUCHING scope protocol and named slicing strategies into subagent implementer prompts and/or plan-authoring guidance.
- **Not competitive:** `frankbria/ralph-claude-code` (anti-aligned), `git-worktree-manager` (already covered).

---

# Cross-cutting findings

## 1. External repos don't ship pipeline harnesses; they ship prompts

All five external repos produced at most 2–4 pipeline-shaped per-step components. None ship Linear-native state transitions, worktree-per-issue isolation, autonomous-mode escape hatches, or programmatic-grading handoffs as a system. Where external repos have distinct value, it's at the **prompt level** (shapes, templates, named techniques) — not at the harness level.

**Implication.** Our pipeline-plumbing layer is the differentiating investment. The external repo survey confirms there's no off-the-shelf harness to adopt wholesale — we build the pipeline, we can selectively import prompts.

## 2. Our overrides vs upstream — all five still earn their place

All five overrides have meaningful, intent-matching diffs against actual `obra/superpowers` v5.0.7 (verified by GitHub fetch, not plugin-cache read). The earlier "identical" finding was a symlink artifact worth correcting in the recon narrative.

**Implication.** No override-drop ADRs triggered from this Pass 1. The patches doc's characterization is accurate.

## 3. There is one clear adopt-immediately upstream gap

`superpowers:verification-before-completion` is an existing upstream skill enforcing "no success claim without fresh verification" that we do not reference anywhere in our ralph pipeline skills. This is exactly the shape of finding PRD open question #2 contemplates. Filed as ADR, separate from any Pass 2 work.

## 4. Primitives worth piloting from external repos

- **Spec-completeness validator script** (from `alirezarezvani/claude-skills` `spec-driven-workflow`'s `spec_validator.py`). A programmatic completeness check at the Phase 1→2 handoff would sharpen the "ralph-ready PRD" quality bar ENG-178 wants to define. Worth piloting before ADR — filed as Pass 2 candidate.

*Initial version of this finding also named HITL/AFK issue tagging (from `mattpocock/skills` `to-issues`) as an ADR candidate. On re-review, the primitive adds per-ticket operator tax for marginal triage value — `/ralph-start` already skips blocked issues, and "Approved but not ralph-ready" is a spec-quality signal better captured upstream in `ralph-spec` than downstream by label filtering. ADR reverted; `to-issues` reclassified as drop.*

## 5. Prompt-level adoptions (non-ADR, low risk)

These are prompt-text-only additions to existing skills or doctrine docs, low-risk enough that a single combined update doesn't warrant an ADR per item:

- **Phase 1 / spec authoring:**
  - Named divergence lenses (Inversion / Audience-shift / 10x / Simplification / Expert-lens) from `addyosmani/agent-skills idea-refine`.
  - "ASSUMPTIONS I'M MAKING → correct me now" opening ritual + three-tier Boundaries scaffold (Always / Ask-first / Never) from `addyosmani/agent-skills spec-driven-development`.
  - "What could kill this idea / what we're choosing to ignore" convergence check from `idea-refine`.
  - Explicit Testing Decisions section in PRD template (from `mattpocock/skills to-prd`) if not already present.
- **TDD / execution discipline:**
  - Horizontal-slicing anti-pattern callout from `mattpocock/skills tdd`.
  - Prove-It Pattern (named bug-fix sequence), Resource Model (Small/Medium/Large test sizing), and Test State Not Interactions callout from `addyosmani/agent-skills test-driven-development`.
  - NOTICED BUT NOT TOUCHING scope-adjacent observation protocol and named slicing strategies (vertical / contract-first / risk-first) from `addyosmani/agent-skills incremental-implementation` into subagent implementer prompts and plan-authoring guidance.

Bundled as follow-up ticket(s), not per-item ADRs.

## 6. Pass 2 pilot pressure is higher than Pass 1 initially estimated

Pass 1's first pass under the "novel-ideas-to-cherry-pick" framing (see finding #7) surfaced only two pilot candidates: `/grill-me` for Phase 1 and SDD-with vs SDD-without codex for Phase 3 shape. Re-scoring under the comparative-arms framing surfaces several more:

- **Phase 1:** `idea-refine` as a second brainstorming-shape pilot alongside `/grill-me`.
- **Phase 2:** `planning-and-task-breakdown` as a plan-abstraction-level pilot alongside the PRD-only baseline.
- **Phase 3:** `incremental-implementation` as an execution-discipline-layer pilot, orthogonal to the shape arms.
- **Phase 3 (prior):** SDD-with vs SDD-without codex tier and single-session vs SDD shape, per the Phase 3 arm list.

**Implication.** The optional numerical-pilot follow-up (from the PRD's Method section) is more likely to trigger than initially estimated. ENG-259's scope expands accordingly — see the revised Ticket structure.

## 7. Recon framing bias: "novel idea to cherry-pick" vs "same-function competitor"

Pass 1's first read defaulted to asking "does this external skill have a novel mechanism we don't have?" That framing systematically undersells same-function competitors by dismissing them as "duplicates X / strictly weaker / no unique mechanism" when what actually differs is an abstraction-level or discipline-layer axis that Pass 2 measurement could resolve. ENG-178's parent goal is *workflow evaluation* — comparative measurement across arms — which makes comparative-arms the correct default framing for this recon.

**Implication.** Under the correct framing, `drop` verdicts should require a named dimension failure (Linear / worktree / autonomous / handoff / CLAUDE.md), not a similarity claim. `pilot` is the cheap safe-default when same-function candidates exist. This finding prompted the re-scoring above.

## 8. Terminal-handoff integration gap class

Our SDD override (and upstream `executing-plans`) terminates at `superpowers:finishing-a-development-branch`, which assumes the session that authored the work also commits it to main. Ralph v2 splits those roles: the autonomous session produces a review artifact via `/prepare-for-review` → Linear In Review; a human merges later via `/close-feature-branch` / `/close-issue`. This terminal mismatch affects every borrowed skill chain that ends in `finishing-a-development-branch`.

**Implication.** A single coexistence patch in `finishing-a-development-branch` itself (detect `.ralph-base-sha`, short-circuit to `/prepare-for-review`) repairs the whole class rather than requiring per-caller patches in SDD, executing-plans, and future arms. Tracked as ENG-265.

---

# Recommended arm lists for ENG-178 Execute parent

## Phase 1: idea → PRD

- **Arm A (default):** `ralph-spec` + our `brainstorming` override.
- **Arm B (pilot):** `ralph-spec` + `/grill-me`-shaped brainstorming prompt (depth-first + codebase-check-first).
- **Arm C (pilot):** `ralph-spec` + `idea-refine`-shaped brainstorming prompt (named-lens divergence).
- *(Dropped from ENG-178's original list:)* Claude native plan mode, GSD-style, hand-written PRD — these are either not-a-harness-shape or already covered by default arm; ENG-178 Phase 1 compares brainstorming shapes, and we have three distinct ones.

## Phase 2: PRD → plan

- **Arm A (default):** our `writing-plans` override.
- **Arm B (pilot):** PRD-only (skip `writing-plans` entirely — feed PRD directly to Phase 3). Tests whether a separate plan phase adds value above the Phase-1 bar.
- **Arm C (pilot):** `planning-and-task-breakdown` (addyosmani) wrapped as the plan writer. Tests whether acceptance-criteria-first abstraction level outperforms upstream's code-specified task contents.
- **Arm D (optional, gated on Phase-1 outcome):** PRD + short approach-paragraph outline.
- *(Dropped:)* snarktank's `ralph` — different-output-shape design question, not a plan-skill arm; mattpocock's `to-issues` — HITL/AFK primitive assessed and rejected (see Phase 1→2 straddler section).

## Phase 3: plan → code

**Shape axis (Arms A–E):**
- **Arm A (default/baseline):** our `ralph-implement`.
- **Arm B:** single-session + per-checkpoint codex.
- **Arm C:** SDD minus Claude reviewers (codex only per task).
- **Arm D:** our full SDD override (three-stage review + final codex). Requires the `finishing-a-development-branch` ralph-awareness patch to run under `claude -p`.
- **Arm E:** SDD decomposition + single-session execution (uses upstream `executing-plans` as the executor). Also subject to the terminal-handoff patch.
- *(No Arm F added by this recon.)* Meta-harness artifact review remains an ENG-178 open question.

**Execution-discipline axis (Arm DI, orthogonal):**
- **Arm DI (pilot):** inject `incremental-implementation` (addyosmani) into subagent implementer prompts; measure against the same-shape baseline (A, D, or E) to isolate the execution-discipline contribution.

---

# ADRs triggered

Two ADRs are filed alongside this recon. They capture recommendations that change our stack immediately, per PRD open question #2 ("ADR to adopt if the recommendation is clear").

1. `2026-04-23-adopt-verification-before-completion-in-ralph-implement.md` — invoke `superpowers:verification-before-completion` from `ralph-implement` Step 4.
2. `2026-04-23-ralph-implement-step-3-scope-tightening.md` — expand `ralph-implement` Step 3 with an explicit scope-adherence checkpoint before Step 4 verification.

A third ADR (`2026-04-23-hitl-afk-label-for-linear-issues.md`) was initially filed and then reverted on re-review — see Cross-cutting finding #4 for the rationale.

Pilot-gated recommendations (expanded pilot candidates, `karpathy-coder`, spec-completeness validator, PRD-only Phase 2, addyosmani planning, etc.) do NOT get ADRs here — they're Pass 2 work.

---

# Ticket structure

- **This recon ticket (ENG-246):** Pass 1 + recon doc + two ADRs. Scope delta vs PRD: Pass 2 is carved out to a follow-up (rationale in the Scope Note at the top — Pass 2 is architecturally "fresh session per component," not a single-session deliverable). ENG-246 still blocks ENG-247 (the Execute parent) as originally planned — ENG-247 needs the arm lists produced here.
- **ENG-259 — Pass 2 pilot shortlist for ENG-246 harness recon.** Blocked by ENG-246; blocks ENG-247. Expanded scope after the comparative-arms re-scoring (finding #7):
  - Phase 1: `/grill-me` and `idea-refine` as brainstorming-shape pilot arms.
  - Phase 2: `planning-and-task-breakdown` as a plan-abstraction-level pilot arm.
  - Phase 3 shape: unresolved C-vs-D ranking after narrative observation.
  - Phase 3 execution-discipline: `incremental-implementation` as an orthogonal-axis pilot.
  - Stack-supporting: `karpathy-coder` as pre-commit warning; spec-completeness validator at Phase 1→2.
- **ENG-260 — Lift cherry-picked prompts from external repos into our skills / doctrine docs.** Independent; does not block ENG-247. Covers the prompt-level items in Cross-cutting finding #5 (Phase 1 spec-authoring cluster + TDD / execution-discipline cluster).
- **ENG-265 — `finishing-a-development-branch` ralph-awareness patch.** Patches the override to detect ralph context (`.ralph-base-sha` present) and short-circuit to `/prepare-for-review` instead of the interactive 4-option menu + direct Linear-Done transition. Blocks ENG-247 Phase 3 Arm D and Arm E (both rely on this terminal). Coexistence-patching, not ongoing investment in the superseded shape; single skill edit + bats coverage.

ENG-178 remains Done. ENG-247 (the Execute parent) stays as-is; its arm lists are replaced by the Recommended Arm Lists section above, and its blocker set becomes {ENG-246, ENG-259, ENG-265}.
