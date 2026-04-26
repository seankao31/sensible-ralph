# Add `/sr-status` command backed by live `progress.json` start/end events

**Linear:** ENG-241
**Project:** Sensible Ralph
**Date:** 2026-04-25
**Blocked by:** ENG-255 (artifact relocation under `.sensible-ralph/`)

## Problem

After `/sr-start` dispatches the orchestrator, there is no feedback while the queue runs. A 4-issue queue can take 1.5+ hours wall-clock (each issue 5–50+ minutes); during that window the only way to tell whether things are progressing is to inspect worktree creation, commits, and Linear state changes by hand. The orchestrator only returns when the entire queue finishes.

## Current state

- `progress.json` is appended atomically after each issue *completes* — good machine-readable post-mortem, but no signal for "started" or "still running."
- `orchestrator.sh` writes almost nothing to stdout; errors go to stderr; per-worktree `<SENSIBLE_RALPH_STDOUT_LOG>` captures the `claude -p` stream but is per-session, not an aggregate.
- `run_in_background` hands Claude Code a silent pipe; no notification surface.
- ENG-255 (Approved, sequenced before this ticket) relocates the orchestrator's artifacts under `.sensible-ralph/` — `.sensible-ralph/progress.json` and `.sensible-ralph/ordered_queue.txt`. This spec assumes the post-relocation paths.

## Solution

Two coordinated changes.

### 1. Make `progress.json` a live artifact

Add a **start** record to `.sensible-ralph/progress.json` when an issue is dispatched, in addition to the existing end record. Both record types gain an `event` field discriminator.

**Start record** (new):

```json
{
  "event": "start",
  "issue": "ENG-208",
  "branch": "eng-208-...",
  "base": "main",
  "timestamp": "2026-04-22T18:42:00Z",
  "run_id": "2026-04-22T18:30:00Z"
}
```

**End records** (existing shape, all outcome variants gain `event: "end"`):

```json
{
  "event": "end",
  "issue": "ENG-208",
  "outcome": "in_review",
  "branch": "eng-208-...",
  "base": "main",
  "exit_code": 0,
  "duration_seconds": 3120,
  "timestamp": "2026-04-22T18:42:00Z",
  "run_id": "2026-04-22T18:30:00Z"
}
```

Field semantics:

- `timestamp` retains its existing meaning: dispatch start time (the moment `claude -p` is about to be invoked). Same field name in both record types — no `started_at` / `completed_at` aliases. End time of an end record is `timestamp + duration_seconds`.
- `run_id` retains its existing meaning: the orchestrator invocation ID, shared by every record from the same run.
- The seven end-record outcome variants are unchanged: `in_review`, `failed`, `exit_clean_no_review`, `setup_failed`, `skipped`, `local_residue`, `unknown_post_state`.

**Legacy records** (written before this change, no `event` field) are not migrated. They will have older `run_id` timestamps and are filtered out before event-discrimination matters in any consumer that reads only the latest run.

### 2. New `/sr-status` skill

Read-only skill that prints a sectioned table for the latest ralph run. Reads `.sensible-ralph/progress.json` and `.sensible-ralph/ordered_queue.txt`. **Zero writes** to Linear, git, or the filesystem. **No network calls** — purely local file reads.

#### Invocation

```
/sr-status
```

No arguments. Run from anywhere inside the repo (the renderer resolves paths via `git rev-parse --show-toplevel`). Frontmatter sets `disable-model-invocation: true` (operator-invoked only) and restricts `allowed-tools` to `Bash`.

#### Output format

Three sections in fixed order: Done, Running, Queued. Empty section shows `(none)`. Footer carries the `run_id` of the rendered run, plus a tip line when Running is non-empty.

```
=== Done (2) ===
  ENG-208  in_review                52m
  ENG-210  failed (exit 7)           3m

=== Running (1) ===
  ENG-211  In Progress              18m  (started 18:42 UTC)

=== Queued (2) ===
  ENG-212
  ENG-213

Run started: 2026-04-22T18:30:00Z
Tip: tail <worktree-base>/eng-211-*/<stdout-log-filename> to see live session output.
```

The tip line uses both configured paths — `$CLAUDE_PLUGIN_OPTION_WORKTREE_BASE` (default `.worktrees`) and `$CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME` (default `ralph-output.log`). The renderer reads both env vars so the tip stays accurate when the operator overrides either default.

Outcome rendering for the Done section:

- `in_review`, `exit_clean_no_review`, `unknown_post_state`, `local_residue`, `skipped` → bare outcome string.
- `failed` → `failed (exit N)` (uses `exit_code`).
- `setup_failed` → `setup_failed (<failed_step>)`.

Duration formatting: seconds → `Xh Ym` if ≥1h, `Xm` if ≥1min, `<1m` otherwise. Scannable, not precise.

#### Renderer logic

`skills/sr-status/scripts/render_status.sh`:

1. Resolve repo root via `_resolve_repo_root` from `skills/sr-start/scripts/lib/worktree.sh` (uses `git rev-parse --git-common-dir`, then `dirname`). This is the same helper the orchestrator uses to anchor `progress.json` writes — critical because `git rev-parse --show-toplevel` returns the linked-worktree path when invoked from a worktree, but `.sensible-ralph/` lives at the main checkout root. The renderer must source the helper from `$CLAUDE_PLUGIN_ROOT/skills/sr-start/scripts/lib/worktree.sh` (matches the source pattern used by `close-issue` and `sr-spec`). If not in a git repo, exit 1 with a clear message.
2. Locate `.sensible-ralph/progress.json`. If absent, print `No ralph runs recorded in this repo. Run /sr-start to dispatch the queue.` and exit 0.
3. Find the latest `run_id` — `jq -r '[.[].run_id] | unique | map(select(. != null)) | sort_by(fromdateiso8601) | last // empty'` from progress.json. The orchestrator always writes `run_id` in normalized UTC form (`date -u +%Y-%m-%dT%H:%M:%SZ`), so `fromdateiso8601` is always parseable; explicit parse beats lexicographic string sort to make the chronological-ordering contract unambiguous in the spec.
4. Filter records to that `run_id`.
5. Partition by `event`:
   - `event == "start"` → start map keyed by `issue`.
   - `event == "end"` → end map keyed by `issue`.
6. Classify per issue:
   - Has end record → **Done** (use end record's `outcome`, `duration_seconds`, `exit_code`, `failed_step`). The presence or absence of a corresponding start record is irrelevant to this classification — an end-only record (e.g., from a failed start-record write) still classifies as Done. The Done row format only uses end-record fields, so the missing start is invisible to the operator.
   - Has start, no end → **Running** (compute elapsed = `now - start.timestamp`).
7. Read `.sensible-ralph/ordered_queue.txt`. Subtract Done + Running issues → **Queued** list (preserves queue order from the file).
8. Render the three sections, then footer.

Edge cases:
- Latest `run_id` returns null (no records, or all records lack `run_id`): fall through to the "No ralph runs recorded" message.
- Latest `run_id`'s record set is empty after `event` partitioning (every record lacks the `event` field — only happens for legacy pre-event-field records, see "Out of scope" below): same fall-through. After the first new run completes, this case becomes unreachable for the latest `run_id`.
- Failed start-record write: the issue exists in `ordered_queue.txt`, the orchestrator dispatched it (Linear is `In Progress`, claude is running), but no start record landed in `progress.json`. The renderer classifies it as Queued. This mis-render self-corrects when the end record lands. Failure modes that produce this state (disk full, permission denied, mid-write I/O error) are pathological and bound to break the orchestrator's other writes too — the broader breakage surfaces the gap; no per-call mitigation in this spec.

#### Crash detection (deferred)

A "Running" row that looks stuck across multiple `/sr-status` invocations usually means the orchestrator died (Esc in the TUI, terminal closed, machine sleep). This skill does not detect that automatically — it shows whatever `progress.json` says. The operator confirms with `pgrep -f orchestrator.sh`.

ENG-254 (Backlog) owns proper crash detection — signal trap in the orchestrator that writes a synthetic `killed_mid_dispatch` end record, plus a PID file at `.sensible-ralph-orchestrator.pid` for liveness checks. When ENG-254 lands, `/sr-status` will be enriched in two small patches:

- Recognize the new `killed_mid_dispatch` outcome → display as `INTERRUPTED` instead of falling through to the Running section.
- Read `.sensible-ralph-orchestrator.pid` and run `kill -0 $pid 2>/dev/null` → annotate Running rows with `(orchestrator alive)` or `(orchestrator dead)`.

Both are post-ENG-254 work. Neither blocks ENG-241.

## Implementation

### Orchestrator changes — `skills/sr-start/scripts/orchestrator.sh`

In `_dispatch_issue`, write the start record **immediately before the `claude -p` invocation** — that is, after the `local prompt=...` construction and after the `local claude_exit=0` initialization, but before the subshell that runs `claude -p`. This narrows the failure window between the start record landing and claude actually starting; a failure during prompt construction (e.g. unreadable `autonomous-preamble.md`) would otherwise leave a permanent "Running" row with no claude session ever invoked and no end record ever written.

```bash
local start_record
start_record="$(jq -n \
  --arg issue "$issue_id" \
  --arg branch "$branch" \
  --arg base "$base_out" \
  --arg ts "$timestamp" \
  --arg run "$run_id" \
  '{event: "start", issue: $issue, branch: $branch, base: $base, timestamp: $ts, run_id: $run}')"
_progress_append "$start_record"
```

Best-effort: matches the existing pattern. `_progress_append` failure does not abort dispatch — the orchestrator continues and writes the end record as usual when claude exits. /sr-status would just be missing this issue from the Running count for the gap window.

Every `_record_*` helper (`_record_setup_failure`, `_record_local_residue`, `_record_unknown_post_state`) and the dispatched-outcome end-record write at the end of `_dispatch_issue` get `event: "end"` added to their JSON. Tainted-skip records (the Phase-2 inline write for skipped issues) also get `event: "end"`.

The `_progress_append` function itself is unchanged — atomic `mktemp + mv` write pattern continues to hold for both record types.

### New skill — `skills/sr-status/`

```
skills/sr-status/
├── SKILL.md
└── scripts/
    ├── render_status.sh
    └── test/
        └── render_status.bats
```

`SKILL.md` is short:

```yaml
---
name: sr-status
description: Read-only status of the current (or most recent) ralph run. Prints a sectioned table — Done / Running / Queued — read from .sensible-ralph/progress.json and .sensible-ralph/ordered_queue.txt. Zero side effects.
allowed-tools: Bash
disable-model-invocation: true
---

# Ralph Status

Print a sectioned table summarizing the latest ralph orchestrator run. Read-only — zero writes to Linear, git, or the filesystem.

Invocation:

    /sr-status

Run from anywhere inside the repo. The renderer resolves paths via `git rev-parse --show-toplevel`.

Output is a sectioned table — Done / Running / Queued — for the latest ralph run. See `docs/usage.md` "Checking progress mid-run" for the operator-facing playbook, and `docs/specs/sr-status-command.md` for the design rationale.
```

The agent invokes `bash "$CLAUDE_PLUGIN_ROOT/skills/sr-status/scripts/render_status.sh"` and prints its stdout verbatim.

### Documentation — `docs/usage.md`

Add a subsection after "What to expect in the morning" titled **"Checking progress mid-run"**:

> Run `/sr-status` from anywhere inside the repo to print a sectioned table — Done / Running / Queued — for the latest ralph run. Read-only, zero side effects. Useful both during a run (to see what's currently dispatching) and after (to glance at the most recent run's outcomes without having to `jq` `.sensible-ralph/progress.json` by hand).
>
> A "Running" row that looks stuck — same elapsed time across multiple checks — usually means the orchestrator died (Esc in the TUI, terminal closed, machine sleep). Confirm with `pgrep -f orchestrator.sh`. Crash detection lands in ENG-254; until then, verify by hand and clean up via the residue paths described above.

Also update `skills/sr-start/SKILL.md`'s "What to expect" pointer to mention `/sr-status` as a faster alternative to manual `jq` inspection.

## Test coverage

### Additions to `skills/sr-start/scripts/test/orchestrator.bats`

1. **Start record present after dispatch.** The single-issue success test additionally asserts that `.sensible-ralph/progress.json` contains a record with `event == "start"`, `issue == "ENG-10"`, `run_id == <run>`. Verify the start record's array index is lower than the end record's (start written before end).
2. **Start record fields.** Assert `branch`, `base`, `timestamp` populated correctly on the start record.
3. **End records gain `event` field.** Every existing test case that asserts an outcome additionally asserts `event == "end"` on that record. Covers all variants: `in_review`, `failed`, `exit_clean_no_review`, `setup_failed`, `skipped`, `local_residue`, `unknown_post_state`. No new test cases — folded into existing assertions.
4. **Atomic-write invariant.** Confirm `_progress_append`'s `mktemp + mv` pattern still holds with the new field. Existing tests cover this implicitly; one explicit assertion: after a simulated mid-write abort (kill jq), the previous progress.json content is intact and parseable by `jq '.'`.

### New file `skills/sr-status/scripts/test/render_status.bats`

5. **No progress.json** → prints "No ralph runs recorded in this repo." and exits 0.
6. **Single in-flight issue** (start record only) → renders under Running with computed elapsed time.
7. **Mixed Done + Running + Queued** → all three sections populated correctly, Done row uses end-record fields, Running row uses start-record fields, Queued list reads from `.sensible-ralph/ordered_queue.txt` minus Done/Running.
8. **All complete** → Done populated, Running and Queued each show `(none)`.
9. **Failed outcome formatting** → `failed (exit 7)`.
10. **`setup_failed` outcome formatting** → `setup_failed (linear_set_state)`.
11. **Latest `run_id` selection** → `progress.json` with two `run_id`s; only the latest is rendered. Records from the older run_id do not appear.
12. **Legacy records (no `event` field)** → progress.json with one legacy record (older `run_id`, no event field) plus one new run; the legacy record is filtered out by `run_id` selection and never reaches event-discrimination logic.
13. **Not in a git repo** → exit 1 with clear message.
14. **Empty `.sensible-ralph/ordered_queue.txt`** → Queued section shows `(none)`.
15. **Out-of-insertion-order `run_id`s** → progress.json containing run_ids in non-chronological array order (e.g. older run_id appears later in the file); the chronologically-latest `run_id` is selected via `sort_by(fromdateiso8601)`, not by array position.
16. **End-only record** → progress.json with an end record but no matching start record for the same issue (simulates a failed start-record write); the issue classifies as Done and renders normally from end-record fields (NOT as Running and NOT as Queued).

All bats tests must pass.

## Acceptance criteria

1. `orchestrator.sh::_dispatch_issue` writes a start record (`event: "start"`, `issue`, `branch`, `base`, `timestamp`, `run_id`) to `.sensible-ralph/progress.json` after `linear_set_state` succeeds and before `claude -p` is invoked.
2. All end-record write paths in `orchestrator.sh` (per-outcome end record at the bottom of `_dispatch_issue`, `_record_setup_failure`, `_record_local_residue`, `_record_unknown_post_state`, and the inline tainted-skip record) include `event: "end"`. The five outcome variants are unchanged otherwise.
3. `_progress_append`'s atomic `mktemp + mv` write pattern continues to hold for both record types — verified by bats.
4. `skills/sr-status/SKILL.md` exists with `disable-model-invocation: true`, no arguments, `allowed-tools: Bash`.
5. `skills/sr-status/scripts/render_status.sh` reads `.sensible-ralph/progress.json` and `.sensible-ralph/ordered_queue.txt`, partitions records from the latest `run_id` into Done / Running / Queued sections, and prints the table format specified above. Zero writes to Linear, git, the filesystem. No network calls.
6. Bats coverage updated per the test list above. All bats tests pass: `bats skills/sr-start/scripts/test/orchestrator.bats skills/sr-status/scripts/test/render_status.bats`.
7. `docs/usage.md` documents `/sr-status` under a "Checking progress mid-run" subsection. `skills/sr-start/SKILL.md`'s "What to expect" guidance mentions `/sr-status` as a faster alternative to manual `jq` inspection.

## Out of scope

- **Stdout milestones / Monitor-based streaming** — separate issue (ENG-242).
- **Desktop notifications** — decided against.
- **Crash detection / orchestrator liveness** — ENG-254 owns this. Forward-looking note above.
- **Linear API state lookup of in-flight issue** — decided against during /sr-spec dialogue (network cost, marginal info: the next end record lands within a minute anyway).
- **Historical run inspection / `--run` flag** — latest `run_id` only.
- **Live-refreshing TUI / continuous mode** — `/sr-status` is one-shot. Operators who want live refresh use `watch -n 5 /sr-status` externally.
- **Pruning / retention policy for `progress.json`** — separate concern.
- **Backward compatibility with pre-event-field `progress.json` records** — this is a v0.1.0 breaking change. Pre-change records remain readable (the schema is still a JSON array of objects) but `/sr-status` may render the latest legacy run as "no records available" until the first new `/sr-start` completes. After that one run, the latest `run_id` always belongs to a new-schema run and the gap closes for all future `/sr-status` invocations. No migration script.

## Commit shape

Single feature commit. Suggested message:

```
feat: add /sr-status command backed by live progress.json start/end events

Add a start record to .sensible-ralph/progress.json when each issue is dispatched,
in addition to the existing end record. Both record types gain an `event`
field discriminator (`start` / `end`).

New /sr-status skill prints a sectioned table — Done / Running /
Queued — for the latest ralph run, read from .sensible-ralph/progress.json and
.sensible-ralph/ordered_queue.txt. Zero side effects, no network calls.

Crash detection (stuck "Running" rows after orchestrator death) lands in
ENG-254; until then operators verify with `pgrep -f orchestrator.sh`.

Closes ENG-241.
```

Branch: `eng-241-add-sr-status-command-backed-by-live-progressjson` (Linear default).
