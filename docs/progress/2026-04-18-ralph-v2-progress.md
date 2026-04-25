# Ralph Loop v2 Rollout — Progress Log

Session-by-session narrative for the ralph v2 rollout. Newest entry first. Each entry records: date, session summary, current state of each ticket, any blockers/decisions for the next session to pick up.

Design spec (source of truth): `../specs/2026-04-17-ralph-loop-v2-design.md`. The rollout plan (`../plans/2026-04-18-ralph-v2-rollout.md`) was deleted after all tickets completed.

---

## 2026-04-22 (session: ENG-178 rescope + workflow evaluation consolidation)

**What happened:**

ENG-177 (spec-to-plan experiments) and ENG-218 (plan-to-code experiments, filed same day) were consolidated into a rescoped ENG-178: "Ralph v2 workflow evaluation: idea → PRD → plan → code." The three experiments share evaluation machinery (task selection, programmatic grading, cost logging, reference methodology) and form a strict pipeline where later phases' inputs are fixed by earlier phases, so splitting them into independent tickets fragmented shared infrastructure and implied parallelism that doesn't exist.

New design doc: `agent-config/docs/specs/2026-04-22-ralph-v2-workflow-evaluation-design.md`. Key additions over the original per-ticket descriptions:

- Reference methodology from a web research pass: Aider leaderboard tabulation, METR time-horizon framing, Terminal-Bench programmatic grading, CodeContests `n@k` metric, LLM-as-judge mitigation stack.
- Meta-harness (Stanford IRIS, arXiv:2603.28052) as a reference point and potential Phase 3 arm F. Their converged TB 2.0 harness artifact is public and worth reading before finalizing Phase 3 arms.
- Contamination caveats from the SWE-bench Illusion paper (arXiv:2506.12286).
- Terminal-Bench 2.0 context: 89 tasks, harbor-native, programmatic grading. Same-model harness spreads of ~10 points on TB 2.0 confirm the signal exists.

**Ticket status snapshot (2026-04-22):**
- ENG-177: **Canceled** — subsumed by ENG-178 rescope.
- ENG-178: **In Progress** — rescoped to three-phase workflow evaluation; design doc committed.
- ENG-218: **Canceled** — subsumed by ENG-178 rescope.
- All other tickets unchanged.

**Handoff:** ENG-178 is in In Progress; branch `eng-178-ralph-v2-workflow-evaluation` has the spec committed. Review and merge when ready, then pick up Phase 1 of the evaluation (build shared evaluation machinery + run brainstorming-shape experiments).

---

## 2026-04-20 (session: post-ENG-184 drift audit + doc alignment)

After closing the ENG-184 worktree, did a real drift check against the design spec. Findings:

**Three drifts captured durably:**
1. **Multi-parent integration merge aborts on conflict** (diverges from spec's "leave conflicts for agent" philosophy — forced by git's MERGING state). Captured in new decision doc `docs/decisions/2026-04-20-ralph-v2-multi-parent-integration-abort.md`. Spec Decision 7 now cross-references the doc.
2. **Outcome model grew from 2 to 6** (`in_review`, `exit_clean_no_review`, `failed`, `setup_failed`, `local_residue`, `unknown_post_state`). Spec Component 2 was still showing the original two-outcome pseudo-code. Updated with the full six-outcome model + classification table + cross-reference to the ambiguous-outcome-handling decision doc.
3. **`worktree_path_for_issue` uses `--show-toplevel`**, which nests new worktrees when invoked from a linked worktree. Already captured as ENG-202; no new doc work needed.

**Three non-drift spec clarifications:**
- 200-char PRD threshold annotation added to Decision 6 (was in code only).
- Cross-project blocker relations explicitly noted as v2 scope limit in Contract Summary; filed **ENG-203** to support multi-project initiatives (v2.1).
- Playbook (`docs/playbooks/ralph-v2-usage.md`) fixed: clarified that the "project" key is configurable (Agent Config is just the default), with a warning about the cross-project scope limit. (Fix was done before the audit — noted here for completeness.)

**Plan-doc bookkeeping fix:** ENG-177 and ENG-178 had all their tasks mass-marked `[x]` despite the work not happening (no `experiments/` directory; Linear states still Todo). Reverted every step in §§ 5–6 back to `[ ]`. A future session opening the plan should see the real state, not the corrupted one.

**Ticket status snapshot (2026-04-20, end-of-session):**
- ENG-184: **Done** (merged earlier today; worktree closed).
- ENG-202: **Backlog** — orchestrator true-repo-root fix.
- ENG-203: **New, Backlog** — cross-project blocker support (v2.1).
- ENG-177, ENG-178: **Todo** — R&D experiments, still open; checkboxes now reflect reality.
- All other ralph v2 tickets unchanged.

**Handoff:** none. Next session picks up whichever ticket matches the moment — ENG-199 (close-feature-branch main-CWD refactor), ENG-202 (orchestrator repo-root fix), ENG-203 (multi-project), ENG-198 (stale-parent check), or the R&D experiments.

## 2026-04-20 (session: ENG-184 review-feedback round — codex P1/P2 + Sean asks)

**What happened this session:**

After posting the initial In Review handoff comment, Sean came back with five questions and asks. Three turned into code changes; two were research questions answered in chat.

**Code changes (all in one commit, `dab6c0f`):**

1. **State-name configurability for plugin release.** Added required config keys `in_progress_state` and `done_state`. Replaced hardcoded `"In Progress"` in `orchestrator.sh::linear_set_state` and `"Done"` in `preflight_scan.sh::_blocker_is_resolved` with new `RALPH_IN_PROGRESS_STATE` and `RALPH_DONE_STATE` env vars. Workspaces that rename their started/completed states now configure them in `config.json`. Addresses codex P1/P2 deferred from prior session.

2. **`linear_get_issue_blockers` rewritten in GraphQL.** Replaced the brittle text-parser for `linear issue relation list` (CLI v2.0.0 has no `--json` flag) with a single `linear api` GraphQL query against `issue.inverseRelations` filtered to `type=="blocks"` via jq. One API call instead of N+1 (no per-blocker `view` loop). The linear-cli plugin documents `linear api` as the GraphQL escape hatch — that's the workaround for the CLI's missing flags.

3. **Absorb config sourcing into entry-point scripts.** `orchestrator.sh`, `preflight_scan.sh`, `dag_base.sh`, and the new `build_queue.sh` auto-source `lib/config.sh` internally if `RALPH_PROJECT` is not already exported. The user no longer needs to invoke from a bash shell — each script's bash shebang ensures bash semantics inside. Set `RALPH_CONFIG=<path>` to override the default. Added `build_queue.sh` to wrap the previous "Step 3-4" user-glue (filter pickup-ready Approved issues, toposort by priority) so the workflow is now `preflight → build_queue → preview → orchestrator` with no inline shell required. Default `config.json` shipped so `/ralph-start` works out of the box.

**Test fix:** discovered while writing the new state-name assertions that bats only fails the test on the LAST command's exit status — series of bare `[[ ]]` assertions silently pass if only the final one is true. Restructured `config.bats` to loop over expected substrings with explicit `return 1`. (This fix did not retroactively expose any previously-broken assertions in other tests, but applying the same pattern to other suites is a candidate follow-up.)

**Linear admin completed this session:**
- ENG-202 filed (related ENG-184): "ralph orchestrator: resolve true repo root via git-common-dir, not show-toplevel" — captures the dogfood-found nested-worktree limitation as a discrete follow-up.

**Research questions answered to Sean (no code change):**
- Linear-cli plugin documents `linear api` as the GraphQL escape hatch for unsupported CLI operations. Used in finding (2) above.
- `lib/config.sh` could be made portable to zsh, but zsh's 1-indexed-by-default array semantics make it awkward. Sean preferred absorbing the source step into the scripts (finding 3) over rewriting config.sh — same end result with smaller surface area.

**Ticket status snapshot (2026-04-20, end-of-second-session):**
- ENG-184: **In Review** — Tasks 1-13 complete. Awaiting Sean's review/merge.
- ENG-202: **Backlog** — new follow-up for nested-worktree fix.
- All other tickets unchanged from prior entry.

**Codex review iteration (this session):** the prepare-for-review re-run surfaced eight more findings across multiple codex passes — each addressed via TDD. Summary: P1 multi-parent merge silently dropped later parents (now fail-fast with abort); P2 stuck-chain check was one-level-deep (recursive `_chain_runnable` with cycle detection); P2 GraphQL inverseRelations capped at 50 (bumped to 250 + hasNextPage refusal); P2 RALPH_PROJECT was a stale-friendly load gate (replaced with RALPH_CONFIG_LOADED marker that carries the resolved config path so cross-repo bleed-through fails the comparison); P2 integration parents weren't accepted from remote-tracking refs (now resolves local-or-`origin/<branch>`); P1 single-parent base had the same fresh-clone bug (same fix applied to `worktree_create_at_base`); P2 `dag_base` filter caught the literal string `"null"` but missed JSON null (now matches both); P1 `build_queue` was excluding Approved-blocker chains entirely (now accepts Done/In Review/Approved blockers); P1+P2 Approved-blocker eligibility — an Approved blocker that's not actually queued (ralph-failed labeled, outside RALPH_PROJECT) was being treated as runnable (now membership-tested against the run's approved set in both `build_queue` and preflight). One codex finding was overruled with empirical evidence: codex claimed `inverseRelations.nodes[].issue` was reading the wrong side, citing linear-visualize's use of `relatedIssue` — but linear-visualize queries `relations` (outgoing) where `relatedIssue` is the other side; this code queries `inverseRelations` (incoming) where `issue` is the other side. A direct API call against ENG-184 confirms the implementation returns the expected blockers (ENG-181/182/183).

**Handoff:** none — branch is in In Review state with a fresh handoff comment posted on Linear. Sean reviews and merges via `/close-feature-branch`.

## 2026-04-20 (session: ENG-184 Tasks 11-12, dogfood + docs sweep)

**What happened this session:**

Resumed after the prior session's Tasks 1-10 handoff. Rebased the branch onto current main (clean — 30 commits replayed without conflicts; new branch base is `76d3218`). Re-ran the bats suite from the rebased tree: 81 tests passing (was 72+ before — the rebase pulled in additional test cases from prior commits).

**Task 11 — end-to-end dogfood: PASS.** Created throwaway issue ENG-201 (Approved, PRD 692 non-whitespace chars). Sourced config, ran preflight (`all clear`), built queue (1 issue, priority 4, base `main`), toposorted, dispatched orchestrator. Orchestrator created the worktree, wrote `.ralph-base-sha=76d3218…` matching `git rev-parse main` exactly, transitioned ENG-201 Approved → In Progress, dispatched `claude -p --permission-mode auto --model opus`, sub-agent created `test-ralph-v2.txt` with `hello\n` + a `.chezmoiignore` entry (Codex review caught the chezmoi-deploy-as-dotfile risk), committed twice, posted Linear handoff comment with QA test plan, transitioned to In Review. Orchestrator exit 0, classified `outcome=in_review`, `duration_seconds=361`, `progress.json` populated correctly with all schema fields including `run_id` (single ISO 8601 timestamp shared across the record). Dogfood worktree + branch removed; ENG-201 canceled with explanatory comment.

**Findings from dogfood (worth flagging, not blocking):**
1. **`source config.sh` is bash-only.** Default zsh on macOS errors with `_config_load:48: bad substitution` because `${!arr[@]}` and `local -a` array semantics differ. Documented in SKILL.md's Prerequisites section in this session.
2. **`worktree_path_for_issue` is CWD-relative, not repo-root-relative.** It resolves the path via `git rev-parse --show-toplevel`, which from inside a linked worktree returns that worktree's own root — the dogfood landed at `<eng-184-wt>/.worktrees/eng-201-…` instead of the documented `<repo>/.worktrees/eng-201-…`. Functionally fine (downstream tools key off `git worktree list`), but violates the convention. Fix would be `git rev-parse --path-format=absolute --git-common-dir` then `dirname`. Documented in SKILL.md's Prerequisites ("invoke from main checkout root"); leaving the code as-is and deferring to follow-up if Sean wants the stricter behavior.

**Task 12 — docs sweep: complete.** Branch diff is pure additions (3,495 insertions across 17 new files under `agent-config/skills/ralph-start/`; no existing files modified). Walked the 8 update-stale-docs surfaces against `--base 76d3218`: ABOUTMEs (no consumer files changed), inline comments (additions only), decision docs (none reference ralph), specs/plans (this entry; design spec stays as historical record), CLAUDE.md (project-root and agent-config — no tech-stack/structure additions worth surfacing), MEMORY.md + memory files (`project_ralph_v2_supersedes_finishing_branch.md` is still accurate), README (mentions playbooks dir but doesn't enumerate playbooks; left alone), related source files (refs in `prepare-for-review/SKILL.md`, `linear-workflow/SKILL.md`, `close-feature-branch/SKILL.md` are all consistent with the implemented orchestrator behavior). Wrote `agent-config/docs/playbooks/ralph-v2-usage.md` (two paragraphs: when to run + morning triage).

**Ticket status snapshot (2026-04-20, end-of-session):**
- ENG-184: **In Progress** — Tasks 1-12 complete; Task 13 (codex review gate + `/prepare-for-review`) remains. Branch `eng-184-implement-ralph-loop-v2-orchestrator-skill` rebased onto `76d3218`.
- All other tickets unchanged from prior entry.

**Handoff for Task 13:** Run `codex-review-gate` against base SHA `76d3218` (post-rebase base; the original `5c4ce7b` scaffold-commit base no longer applies). Address blocking findings; if any code changes, re-run the dogfood. Then `/prepare-for-review` to post the Linear handoff and move ENG-184 to In Review.

## 2026-04-20 (session: ENG-184 library + orchestrator, Tasks 1-10 complete)

**What happened this session:**

Executed ENG-184 Tasks 1-10 via `superpowers:subagent-driven-development` in a worktree at `.worktrees/eng-184-implement-ralph-loop-v2-orchestrator-skill`. All library and orchestrator code is written and tested. 72+ bats tests passing. 21 commits on branch. Tasks 11 (end-to-end dogfood), 12 (docs sweep), 13 (review gate + `/prepare-for-review`) remain.

**Design decisions made or empirically resolved this session:**
1. **Worktree location = `<repo>/.worktrees/<branch>`** (chezmoi's existing convention; matches `superpowers:using-git-worktrees` default). Design doc at line 45 previously claimed `~/.claude/worktrees/` was the native `claude --worktree` convention — verified false. Design doc + plan corrected.
2. **Orchestrator does NOT use `claude --worktree`.** That flag is create-only (branches off HEAD into `<repo>/.claude/worktrees/<name>`) and has no DAG/integration-merge awareness. Orchestrator calls `git worktree add` itself, then `(cd $worktree && claude -p ...)` via subshell. Design doc pseudo-code updated.
3. **Q2 resolution (permission-prompt deadlock):** empirical probe with `git push origin main` under `--permission-mode auto` showed the sub-agent **refuses and continues** — exit 0, no hang, no non-zero. Denials surface as tool results; agent reports and exits cleanly. This means exit-code alone does NOT imply success. Orchestrator now classifies by exit code AND post-dispatch Linear state transition:
   - exit=0 AND state==`$RALPH_REVIEW_STATE` → `in_review`
   - exit=0 AND state!=`$RALPH_REVIEW_STATE` → `exit_clean_no_review` (labeled `ralph-failed`, downstream tainted)
   - exit!=0 → `failed` (labeled `ralph-failed`, downstream tainted)
4. **Linear CLI limitations (verified empirically):**
   - `linear issue view --json` does NOT include relations (only `identifier`, `branchName`, `state`, etc.)
   - `linear issue relation list` does NOT support `--json`
   - `linear issue update --state` takes a state *type* (unstarted/started/etc.), NOT a state name — `--state unstarted` filters too broadly, so the orchestrator omits `--state` and filters by `state.name` in jq
   - `linear issue update --label` REPLACES all labels; `lib/linear.sh::linear_add_label` implements fetch-then-update to preserve existing labels
   - Default query limit is 50 issues (`--limit 0` for unlimited)
5. **`.ralph-base-sha` for INTEGRATION bases records main's SHA (pre-merge), not post-merge HEAD.** This keeps `prepare-for-review`'s review-diff scope correct when parent merges conflict.
6. **Per-issue fault isolation in orchestrator.** Setup failures (branch lookup, dag_base errors, worktree creation, base-sha write, Linear state transition, etc.) record `outcome: "setup_failed"` with a `failed_step` identifier, clean up worktree state IF this invocation created it (never touches pre-existing directories/branches), taint descendants, and continue to the next issue. Phase-1 blocker-fetch failures also isolated. Post-dispatch state/label-add failures tolerated.
7. **Progress.json schema**: flat array of per-issue records; each record carries `run_id` (ISO 8601 UTC timestamp captured once at orchestrator start). Consumers can group by `run_id`. Did NOT adopt design doc Component 6's nested `{"runs": [{...}]}` schema — YAGNI, easy to post-process if needed.

**Admin items completed this session:**
- ENG-184 Linear ticket description updated (`/run-queue` → `/ralph-start`, `agent-config/skills/run-queue/` → `agent-config/skills/ralph-start/`).
- ENG-177 and ENG-178 set to `blocked-by ENG-184` in Linear (rollout plan line 141 requirement).

**Known limitations / conscious trade-offs:**
- `lib/linear.sh::linear_get_issue_blockers` parses text output of `linear issue relation list` (the CLI has no JSON option for relations in v2.0.0). Brittle to CLI format changes. Documented inline with the expected format.
- `run_id` is second-resolution. Concurrent `/ralph-start` invocations within the same second could collide — explicitly unsupported (single-invocation-at-a-time by design).
- progress.json uses tmpfile+mv, atomic for single-writer but does not prevent lost updates in concurrent writers (no `flock`). Acceptable given single-invocation design.
- Task 8 codex iterations were cut off after ~7 rounds when findings transitioned from "critical correctness" to "extreme edge cases." Task 13's final review gate (codex via `/prepare-for-review`) is the safety net.

**Ticket status snapshot (2026-04-20):**
- ENG-182, ENG-186, ENG-197: **Done** ✓
- ENG-184: **In Progress** (this session; Tasks 1-10 of 13 complete; branch `eng-184-implement-ralph-loop-v2-orchestrator-skill`; 21 commits)
- ENG-185: **Canceled** — replaced by ENG-198
- ENG-198: **Backlog** — blocked-by ENG-184
- ENG-199: **Todo** — follow-up to ENG-197; worktree-path convention is now fixed at `.worktrees/<branch>`, so ENG-199 can proceed independently
- ENG-193, ENG-194: **Backlog** — lower priority
- ENG-177, ENG-178: **Todo** — now blocked-by ENG-184 (relations set this session); R&D experiments, need Sean's subjective evaluation

**Handoff for next session (Tasks 11-13 of ENG-184):**

Required work to finish ENG-184:

1. **Task 11 — end-to-end dogfood.** Start a fresh session (the current one spawned many subagents + is ~40%+ context). In the ENG-184 worktree:
   - Create `config.json` from `config.example.json` (`cd agent-config/skills/ralph-start && cp config.example.json config.json`). Defaults should work as-is.
   - Create a throwaway Linear issue in Agent Config project, state=Approved, trivial PRD (≥200 non-whitespace chars required by preflight). E.g., "Create `test-ralph-v2.txt` containing the text `hello`. This is a dogfood test of the ralph v2 orchestrator. The implementation should consist of a single-file commit. Commits must be small. Test plan: verify the file exists at repo root with expected contents."
   - Invoke the skill (NOT as `/ralph-start` since the skill file isn't symlinked yet — instead run the scripts directly from the skill directory). Sequence: `source scripts/lib/config.sh config.json` → `scripts/preflight_scan.sh` → build queue via `linear_list_approved_issues` + filter → `scripts/toposort.sh` → show preview → `scripts/orchestrator.sh ordered_queue.txt`.
   - Observe: worktree created, session dispatched, Linear state In Review, `progress.json` populated, `.ralph-base-sha` in the worktree.
   - Root-cause any failures per CLAUDE.md. Do NOT mark the task done with known failure modes.
   - Cancel the throwaway issue when done, with a comment noting it was a dogfood test.

2. **Task 12 — docs sweep.** Invoke `update-stale-docs` skill. Write a short playbook at `agent-config/docs/playbooks/ralph-v2-usage.md` (two paragraphs on "how I use this" from Sean's seat: when to run, what to expect, how to triage `ralph-failed` issues).

3. **Task 13 — review gate.** Invoke `codex-review-gate` on the branch diff (base SHA for the branch: `5c4ce7b` — the scaffold commit on main). Address blocking findings. Re-run Task 11 dogfood if code changed during review. Invoke `/prepare-for-review` to post the Linear handoff comment and move ENG-184 to In Review.

4. **Close via ENG-199 (if merged first) or `close-feature-branch` or manual rebase+ff-only.**

**Open design questions carried forward:** None from ENG-184 — all Q1-Q4 are resolved.

## 2026-04-19 (session: handoff to a new session after ENG-182/186 merged)

**What happened between sessions:**
- The user reviewed and merged ENG-182 and ENG-186 to main. Both are now **Done** in Linear.
- ENG-186 was relocated during merge to `.claude/skills/close-feature-branch/` (project-local `.claude/skills/` rather than `agent-config/skills/`). This makes it invokable as a project-local slash command without chezmoi symlink plumbing.
- The user filed three follow-up tickets from the review:
  - **ENG-197** — "Reorder close-feature-branch skill: detach HEAD + worktree-remove-last." **State: Approved, priority ⚠⚠⚠ (urgent).** Fixes an issue in ENG-186's close ritual.
  - **ENG-193** — "update-stale-docs: accept explicit base SHA instead of relying on working-tree diff." State: Backlog. Resolves the known limitation flagged in yesterday's design decisions (item 2).
  - **ENG-194** — "prepare-for-review: paginate Linear comment list in dedup check." State: Backlog. Addresses the P3 pagination limitation documented in ENG-182's SKILL.md.

**This session (ENG-185 design decision):**
- The user canceled ENG-185 (post-commit git hook for stale-parent detection) and replaced it with **ENG-198** — "Add stale-parent check to close-feature-branch skill." Same detection moves from commit-time (git hook) to review/merge-time (one-liner inside `close-feature-branch`: `git merge-base --is-ancestor $parent_head HEAD`). Rationale: no existing hook infrastructure in chezmoi, per-commit Linear API cost, and the incident hasn't occurred yet (ENG-184 isn't even built) — classic YAGNI. Full cancellation comment on ENG-185. ENG-198 is blocked-by ENG-184 and sits in Backlog; not actionable until ralph v2 has been running long enough to produce multi-level DAG dispatches in practice.

**This session (ENG-197 dogfood close + findings):**
- Ran `/close-feature-branch` on ENG-197 itself. Merged to main as `808ab5c`. Linear: Done.
- **Finding 1 — skill bug, fixed inline:** The skill rebased onto `origin/main`, which silently skipped the user's unpushed local-main commits. Step 2's ff-merge then failed when local main was ahead of origin. Hit live: local main had `0910e0d` (the ENG-185 cancellation log entry) that the rebase ignored. Switched to `git rebase main`. Committed in the same close as part of ENG-197. The rollout plan's Step 1 sketch was updated for the same reason.
- **Finding 2 — design doc misattribution at line 45:** The spec claims `~/.claude/worktrees/<branch>` is the "native `claude --worktree` convention." It isn't. The flag's actual native default is `<repo>/.claude/worktrees/<name>` (relative to repo, not in home). Our home-dir choice is defensible (worktrees outside the repo, accessible across multiple projects) but the justification is wrong. Worth a copy-edit on the design doc; not a behavior change. **Open question:** should we keep `~/.claude/worktrees/` (design's choice), switch to `<repo>/.claude/worktrees/` (so `claude --worktree` "just works"), or keep the existing `<repo>/.worktrees/` convention used in chezmoi today?
- **Finding 3 — ENG-197's reorder is necessary but not sufficient.** ENG-197 protects against the *intentional* worktree-removal path destroying the Bash session mid-ritual. But today the worktree directory vanished *before* Step 7 ran (cause unknown — between the successful Linear update and the failed `git worktree remove` attempt, nothing in the session ran that should have touched it). The Bash tool died the moment the CWD was gone, regardless of cause. `dangerouslyDisableSandbox` did not bypass the path-exists check. ENG-197 still helped: branch delete and Linear transition both ran successfully because they came before the disappearance. But the residual gap matters: as long as the close session is pinned inside the worktree being closed, *any* external cause (manual rm, watcher process, hook) destroys the session.
- **Filed as ENG-199:** Refactor `close-feature-branch` to run from main-checkout CWD using `git -C "$WORKTREE_PATH" …` for worktree-side operations. Skill takes the issue ID as an argument and resolves the worktree path via `git worktree list --porcelain`. The user's review workflow stays the same (still cd into worktree to review), but the *close* step is invoked from a separate session started at the project root. Removes the CWD-pinning class of failure entirely. State: Todo; coordinate with ENG-184's worktree-path convention (see workflow finding below).
- **Workflow finding for next-session worktree convention:** When ralph v2 (ENG-184) ships, the orchestrator will create worktrees at the design's chosen path. The location decision (above) and the close-skill refactor (above) should be coordinated with ENG-184's pre-creation step so that the close skill knows where to find worktrees. This is not a blocker — pick a convention, document it once, both ENG-184 and the close-skill refactor read from the same constant.

**Ticket status snapshot (2026-04-19):**
- ENG-182: **Done** ✓
- ENG-186: **Done** ✓ (relocated to `.claude/skills/`)
- ENG-197: **Done** ✓ (this session; merged as `808ab5c`).
- ENG-184: **Todo**, unblocked. Critical-path: the orchestrator itself.
- ENG-185: **Canceled** — replaced by ENG-198 (review-time check instead of commit-time hook).
- ENG-198: **Backlog** — new follow-up; blocked-by ENG-184. Pick up after ralph v2 is live.
- ENG-199: **Todo** — new follow-up to ENG-197; refactor `close-feature-branch` to run from main-checkout CWD. Coordinate worktree-path convention with ENG-184.
- ENG-193, ENG-194: **Backlog** — lower priority, not blocking anything.
- ENG-177, ENG-178: **Todo** — R&D experiments, need the user's subjective evaluation.

**Recommended priority for the next session:**
1. ~~ENG-197 (Approved + urgent; fixes something the user already merged).~~ **Done this session.**
2. ENG-184 — the big one. Coordinate with ENG-199 on worktree-path convention before coding the path.
3. ENG-199 — follow-up to ENG-197; can land independently of ENG-184 once the worktree-path convention is decided.
4. ENG-193, ~~ENG-194~~ — backlog cleanup. ~~ENG-194~~ **In Review** (server-side comment filter, 2026-04-20).
5. ENG-177, ENG-178 — need the user's involvement, not autonomous work.

**Open design questions carried forward:**
- ENG-184 open questions: Q2 (permission-prompt deadlock) remains contested; test empirically at Task 8.

## 2026-04-18 (session: plan reconstruction + autonomous rollout start)

**What happened:**
- Reconstructed this plan from scratch after the ENG-176 worktree was force-removed with the original plan.md untracked (unrecoverable).
- Resolved open questions Q1, Q3, Q4 with the user's answers; flagged Q2 as contested with pointers to design doc lines 185 and 468.
- Renamed skill from `run-queue` to `ralph-start` throughout the plan (Q4 resolution). ENG-184 ticket description still says `run-queue` — update it during ENG-184 execution.
- Started autonomous execution: ENG-182 in a dedicated worktree.

**Ticket status at end of session:**
- ENG-182: **In Review** ✓ — SKILL.md complete, 24 Codex review passes, handoff comment posted. Branch: `eng-182-create-prepare-for-review-skill`. Key open design item for ENG-184: orchestrator must write `.ralph-base-sha` to each worktree before dispatch.
- ENG-186: **In Review** ✓ — close-feature-branch SKILL.md complete, 5 Codex review passes, handoff comment posted. Branch: `eng-186-project-local-close-feature-branch-skill-for-chezmoi`. Has a forward-reference to `/prepare-for-review` that works once ENG-182 ships.
- ENG-184: Not started (unblocked once ENG-182 merges)
- ENG-185: **Stopped at discovery phase** — needs the user's design decision on install mechanism. Findings: no existing git hook infrastructure in this repo (only `.git/hooks/*.sample` files, no `core.hooksPath` set globally or locally, no `.githooks/` dir). The `agent-config/hooks/` directory that exists is for Claude Code event hooks, not git hooks. **Design question for the user:** Should the post-commit git hook install globally (via `git config --global core.hooksPath ~/.config/git/hooks` + chezmoi-managed script), or per-repo, or some other mechanism? The plan's Task 1 says "pause and ask the user" at this branch point — not proceeding without a decision.
- ENG-177: Not started
- ENG-178: Not started

**Design decisions made this session:**
1. **Sequence reordered from design doc:** Codex review gate runs AFTER docs/decisions updates (Steps 1-3 then Step 4), not before. This ensures the review sees the full final branch state in one pass.
2. **`update-stale-docs` limitation:** It uses `git diff --stat` (working tree diff, empty on clean tree). Work around: provide `git diff "$BASE_SHA" HEAD --stat` as context. Filed as a known limitation — **resolved by ENG-193**, which added `--base <sha>` support to the skill.
3. **`.ralph-base-sha` file:** Orchestrator (ENG-184) must write this to the worktree before dispatch so `prepare-for-review` can scope its review/summary to just the task's commits, not all of main.
4. **Linear CLI is required:** Removed false claim that `linear-workflow` is a fallback for CLI failures — it uses the same CLI binary. If Linear CLI is unavailable, the skill cannot complete.
5. **SHA-based comment dedup** (not header-based): avoids duplicate posting on retry while allowing re-runs after feedback commits.

**Decisions/issues for the next session:**
- ENG-182 and ENG-186 are In Review on their own branches. The user's review merges both.
- ENG-184 is unblocked once ENG-182 merges. Key contract from ENG-182 for ENG-184: orchestrator.sh must write `.ralph-base-sha` to each worktree at dispatch time (before the session's first commit). This file records the SHA where the session started and is what `prepare-for-review` uses to scope codex review + handoff summary.
- **ENG-185 needs a design decision before it can proceed** — see above. Install mechanism is the blocker.
- ENG-177 and ENG-178 are R&D experiments; not attempted this session (open-ended, not amenable to autonomous execution without the user's subjective evaluation).
- Open Q #2 (permission-prompt deadlock) remains contested — resolve empirically at the start of ENG-184 Task 8.
- ENG-182 → ENG-184 dependency: ENG-184 orchestrator script must write `.ralph-base-sha` to each worktree at dispatch time (recording `git rev-parse HEAD` before the first commit). This contract is documented in prepare-for-review's SKILL.md and must be implemented in ENG-184's orchestrator.sh.
- ENG-183 is Done but the linear-workflow SKILL.md's graphviz diagram already shows `prepare-for-review` as a handoff node — no updates needed there.
- ~~Consider filing a follow-up ticket to make `update-stale-docs` use branch diff (not working tree diff).~~ Done — ENG-193 added `--base <sha>` support.
