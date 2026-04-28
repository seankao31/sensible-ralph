# Surface autonomous-session diagnostics for non-success outcomes

## Problem

When an autonomous `claude -p` session ends in a non-success outcome
(`exit_clean_no_review`, `failed`, `setup_failed`, `unknown_post_state`),
the operator's only built-in signal is the per-issue worktree log at
`<worktree>/<CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME>` (default
`ralph-output.log`). That file contains **only the agent's final response
to stdout** — typically a sentence or short paragraph — because
`claude -p` doesn't print intermediate tool work to stdout. For
pathological exits the log is nearly useless: ENG-294 ended
`exit_clean_no_review` after a nested-skill bug
([anthropics/claude-code#17351](https://github.com/anthropics/claude-code/issues/17351))
with `ralph-output.log` containing a single sentence ("Doc sweep is
complete; no other surfaces need updating"), and diagnosing required
recognizing Claude Code's project-slug naming convention, hand-finding
the session JSONL, and grep'ing 600 KB of transcript.

A plugin user without insider knowledge of where Claude Code persists
session transcripts is stuck. The `progress.json` end record carries the
outcome label but no path to richer context.

## Goal

Make autonomous-session failures **diagnosable from the operator's
existing ritual** (`/sr-status`, `progress.json`, the worktree) without
requiring knowledge of where Claude Code stores session transcripts.

## Scope

Three changes, layered on the existing pipeline. Composition: **A + C + E**
from the originating brainstorm. Heuristics for (C): **H1 + H2 + H3**
from the four candidates; **H4** (auto-mode refusal pattern) is
explicitly deferred. Approaches **B** (auto-summarize via fast-claude)
and **D** (`/sr-diagnose` command) are out of scope and become candidate
follow-up issues if the v1 surface proves insufficient.

1. **Orchestrator capture (A).** Pre-generate a UUID per dispatch, pass
   it to claude as `--session-id`, and write `session_id` and
   `transcript_path` into both `start` and `end` records in
   `progress.json`. The transcript path is constructed deterministically
   from the worktree absolute path via Claude Code's slug convention
   (`/` → `-`).

2. **Diagnosis pass (C).** A new helper
   `skills/sr-start/scripts/diagnose_session.sh` runs three heuristics
   against the worktree and (where eligible) the JSONL transcript, emits
   a one-line composed `hint`, and the orchestrator threads the hint
   into the end record.

3. **Status surface (E).** `render_status.sh` renders the `hint`,
   `transcript_path`, and the worktree log path as an indented sub-block
   under each non-success Done row. Successful (`in_review`) and
   `skipped` rows stay one-line.

## Mechanism

### A — session-id capture

`claude -p --session-id <uuid>` accepts a precomputed UUID and uses it as
the persisted session ID. (Confirmed via `claude --help`: the
`--session-id <uuid>` flag accepts any valid UUID.) The orchestrator
generates one per dispatch with `uuidgen | tr 'A-Z' 'a-z'`.

`uuidgen` is a runtime requirement on macOS and Linux (every macOS box
ships it; util-linux provides it on every mainstream Linux distro). The
spec asserts this requirement; no fallback is engineered.

The transcript path is computed in shell, not by introspecting Claude
Code internals:

```bash
slug="${path//\//-}"   # absolute worktree path with / → -
transcript_path="$HOME/.claude/projects/${slug}/${session_id}.jsonl"
```

The slug rule is verified by inspection of `~/.claude/projects/` on this
host and by Claude Code's documented behavior; it is the cwd absolute
path with every `/` replaced by `-`. The orchestrator dispatches via
`(cd $path; claude -p ...)` so cwd = worktree path; the slug is a pure
function of that path.

`transcript_path` is stored as an absolute path (not `~`-relative) so
copy-paste into a fresh shell works without depending on tilde expansion.
It is **not** validated at write time: the JSONL may not exist yet when
the start record is written.

### C — diagnosis pass

New file: `skills/sr-start/scripts/diagnose_session.sh`. Pure helper —
no Linear writes, no `progress.json` writes, no state mutation. Reads
git state and (optionally) the JSONL; writes one line to stdout.

**Invocation:**

```
diagnose_session.sh <outcome> <worktree_path> <spec_base_sha> <transcript_path>
```

- `<outcome>` — one of the seven outcome strings.
- `<worktree_path>` — absolute path to the worktree; cwd for git commands.
- `<spec_base_sha>` — the SHA captured by the orchestrator post-merge,
  pre-dispatch (already at `<worktree>/.sensible-ralph-base-sha` per
  `docs/design/worktree-contract.md`). Passed explicitly so the
  orchestrator stays the single source of truth.
- `<transcript_path>` — full absolute path the orchestrator computed.

**Output:**

- stdout: zero or one line. The line is the composed hint. Heuristics
  are joined with `; ` when more than one fires. Empty match → no
  output (caller checks for empty string).
- stderr: silent at default verbosity. Per-heuristic decisions go to
  stderr only when `RALPH_DIAGNOSE_DEBUG=1`.
- Exit code: always 0 unless misinvoked (missing positional arg). A
  failed individual heuristic is silently dropped.

**Outcome eligibility matrix:**

| Outcome | H1-nocommits | H2-dirtytree | H3-skill-context-loss |
|---|---|---|---|
| `in_review` | n/a — script not invoked | n/a | n/a |
| `exit_clean_no_review` | yes | yes | yes |
| `failed` | yes | yes | yes |
| `unknown_post_state` | yes | yes | no |
| `setup_failed` | no — `failed_step` is the correct diagnostic | no | no |
| `local_residue` | n/a — script not invoked | n/a | n/a |
| `skipped` | n/a — script not invoked | n/a | n/a |

The orchestrator decides whether to call the script based on outcome;
the script accepts every outcome but no-ops when it doesn't apply.

**Heuristics (v1):**

- **H1-nocommits** (always-on for eligible outcomes). `git rev-list
  "$spec_base_sha"..HEAD --count` on the worktree branch. When 0,
  emit `no implementation commits`. Validate `spec_base_sha` exists
  (`git cat-file -e "$spec_base_sha^{commit}"`) before counting; on
  validation failure, suppress the heuristic.

- **H2-dirtytree** (always-on for eligible outcomes). `git status
  --porcelain` non-empty → emit `uncommitted edits left in worktree`.

- **H3-skill-context-loss** (gated to `failed` /
  `exit_clean_no_review` only). Defensive JSONL parsing: read up to
  the last 5 events whose `type == "assistant"`. Fire if (a) at least
  one of those events contains a tool_use whose `name == "Skill"`, AND
  (b) no chronologically-later event in the window contains any
  tool_use. Emit `context-loss after Skill (<skill-name>)
  (claude-code#17351)`.

  JSONL parsing posture: **defensive, suppress on uncertainty.** If the
  JSONL is missing, unreadable, or any `jq` access errors, the
  heuristic is silently suppressed. If a future Claude Code release
  changes the JSONL schema (which is undocumented internal format),
  the heuristic stops firing rather than emitting wrong hints. This
  trade-off — under-report rather than mis-report — is the explicit
  design choice for JSONL-dependent heuristics.

  `tac` is not on macOS; the implementation must use `tail -r` (BSD)
  or an `awk` line-reverser. Implementer choice.

  Skill-name extraction: read
  `.message.content[] | select(.type == "tool_use" and .name == "Skill") | .input.skill`
  from the matched assistant turn. If the path doesn't resolve, emit the
  hint without the parenthetical name (`context-loss after Skill
  (claude-code#17351)`); never fail the heuristic over name lookup.

**Composition:** order is H1 → H2 → H3 (git facts first, then JSONL
inference). Empty array → no output.

### E — status surface

Modify the Done-section render loop in
`skills/sr-status/scripts/render_status.sh` (lines 165–179): after the
existing one-line row, if `outcome` is not `in_review` and not
`skipped`, render an indented sub-block:

```
  ENG-294  exit_clean_no_review      14m
    ↳ no implementation commits; context-loss after Skill (using-superpowers) (claude-code#17351)
      transcript: <repo_root>/<worktree-base>/<branch>/<stdout-log-filename>
      session: <transcript_path>
```

- `↳` is U+21B3 — emitted as the UTF-8 byte sequence `\xe2\x86\xb3`
  (`printf '\xe2\x86\xb3'`) so the renderer doesn't depend on the source
  file's encoding being preserved through editing tools.
- The `transcript:` line is the worktree log path (`ralph-output.log`),
  not the JSONL — operators get both, with the worktree log being the
  faster glance and the session JSONL being the deep-dive option.
- The `session:` line is omitted if the end record has no
  `transcript_path` (legacy records or `setup_failed`/`local_residue`
  records that lack the field).
- The `↳` line is omitted if the end record has no `hint` field
  (heuristics ran but matched nothing, or the record predates this
  change).
- `skipped` rows stay one-line — they have no transcript, no session,
  and the operator already knows the upstream cause; surfacing an empty
  sub-block under each one would be visual noise.

The pre-existing footer "Tip: tail …" line for the in-flight Running
row stays unchanged.

## `progress.json` schema additions

Three new fields. Purely additive; old consumers (operators reading
only `outcome`, the existing renderer pre-deploy) keep working.

### `session_id`
- **Where:** `start` records and dispatched-outcome `end` records
  (`in_review`, `exit_clean_no_review`, `failed`, `unknown_post_state`).
- **Not on:** `setup_failed`, `local_residue`, `skipped` records — these
  never invoke `claude -p`.
- **Format:** lowercase canonical UUID v4 string.

### `transcript_path`
- **Where:** same records as `session_id`.
- **Value:** `<HOME>/.claude/projects/<slug>/<session_id>.jsonl` as
  computed in shell. Stored as absolute path.
- **Not validated at write time.**

### `hint`
- **Where:** end records on `exit_clean_no_review`, `failed`,
  `unknown_post_state`. The diagnose pass is invoked for these three
  outcomes only.
- **Format:** single string, semicolon-separated when multiple
  heuristics fire. **Field is omitted entirely** when no heuristic
  matched (do not write `"hint": ""`; absent is cleaner for `jq`
  consumers).
- **Not on `in_review`, `setup_failed`, `local_residue`, or `skipped`:**
  successful sessions don't get diagnostic noise; `setup_failed` is
  already characterized by `failed_step`; `local_residue` and `skipped`
  never invoked claude.

### Illustrative end record (`exit_clean_no_review`)

```json
{
  "event": "end",
  "issue": "ENG-294",
  "branch": "eng-294-write-docsdesignorchestratormd",
  "base": "main",
  "outcome": "exit_clean_no_review",
  "exit_code": 0,
  "duration_seconds": 832,
  "timestamp": "2026-04-26T22:14:08Z",
  "run_id": "2026-04-26T22:00:00Z",
  "session_id": "ecff8ef9-5ab7-4159-b86c-80fea80919c6",
  "transcript_path": "/Users/seankao/.claude/projects/-Users-seankao-Workplace-Projects-sensible-ralph--worktrees-eng-294-write-docsdesignorchestratormd/ecff8ef9-5ab7-4159-b86c-80fea80919c6.jsonl",
  "hint": "no implementation commits; context-loss after Skill (using-superpowers) (claude-code#17351)"
}
```

## Orchestrator wiring

Three edits to `skills/sr-start/scripts/orchestrator.sh`, all confined
to `_dispatch_issue` and the start/end record-emission paths.

### Edit 1 — pre-generate `session_id` and compute `transcript_path`

Inserted after `path` is resolved (line ~395 region) and before the
start-record write. Done once per issue and reused for both records.

```bash
local session_id; session_id="$(uuidgen | tr 'A-Z' 'a-z')"
local slug; slug="${path//\//-}"
local transcript_path="$HOME/.claude/projects/${slug}/${session_id}.jsonl"
```

### Edit 2 — thread fields into start record + claude invocation

Existing start-record write gets two `--arg` additions and two new keys
in the `jq` body:

```bash
start_record="$(jq -n \
  --arg issue "$issue_id" \
  --arg branch "$branch" \
  --arg base "$base_out" \
  --arg ts "$dispatch_timestamp" \
  --arg run "$run_id" \
  --arg sid "$session_id" \
  --arg tp "$transcript_path" \
  '{event: "start", issue: $issue, branch: $branch, base: $base,
    timestamp: $ts, run_id: $run, session_id: $sid, transcript_path: $tp}')"
```

Existing dispatch invocation gains one flag:

```bash
claude -p \
  --permission-mode auto \
  --model "$CLAUDE_PLUGIN_OPTION_MODEL" \
  --name "$issue_id: $title" \
  --session-id "$session_id" \
  "$prompt" \
  2>&1 | tee "$path/$CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME"
```

### Edit 3 — invoke `diagnose_session.sh` and thread hint into end record

Inserted after outcome classification, before the existing end-record
write. The spec-base-sha is read from `<path>/.sensible-ralph-base-sha`
(written pre-dispatch per `docs/design/worktree-contract.md`).

```bash
local hint=""
case "$outcome" in
  exit_clean_no_review|failed|unknown_post_state)
    local spec_base_sha=""
    if [[ -r "$path/.sensible-ralph-base-sha" ]]; then
      spec_base_sha="$(cat "$path/.sensible-ralph-base-sha")"
    fi
    if [[ -n "$spec_base_sha" ]]; then
      hint="$(bash "$SCRIPT_DIR/diagnose_session.sh" \
        "$outcome" "$path" "$spec_base_sha" "$transcript_path" 2>/dev/null)" || hint=""
    fi
    ;;
esac
```

Then in the end-record `jq -n` invocation, conditionally include the
`hint` field:

```bash
record="$(jq -n \
  --arg issue "$issue_id" \
  --arg branch "$branch" \
  --arg base "$base_out" \
  --arg outcome "$outcome" \
  --argjson exit_code "$claude_exit" \
  --argjson duration "$duration" \
  --arg ts "$dispatch_timestamp" \
  --arg run "$run_id" \
  --arg sid "$session_id" \
  --arg tp "$transcript_path" \
  --arg hint "$hint" \
  '{event: "end", issue: $issue, branch: $branch, base: $base, outcome: $outcome,
    exit_code: $exit_code, duration_seconds: $duration, timestamp: $ts,
    run_id: $run, session_id: $sid, transcript_path: $tp}
   + (if $hint == "" then {} else {hint: $hint} end)')"
```

The `+ (if $hint == "" then {} else {hint: $hint} end)` idiom keeps the
field absent (not empty) when no heuristic fires.

`_record_unknown_post_state` follows the same pattern: pass
`session_id`, `transcript_path`, and `hint` in; emit with the same
conditional-presence idiom. `_record_setup_failure` and
`_record_local_residue` remain unchanged — they don't get `session_id`
fields per the schema above.

### What the orchestrator does NOT do

- **No JSONL parsing inline** — that lives in `diagnose_session.sh`.
- **No transcript-path validation** — the helper defends; the
  orchestrator trusts.
- **No retry on diagnose failure** — if the helper crashes or times
  out, hint stays empty and the end record lands without it. The
  diagnostic surface is best-effort augmentation, not a critical-path
  dependency.
- **No change to `--output-format`** — keep stdout text mode and the
  `tee` to `ralph-output.log` exactly as today. The transcript is what's
  new; the operator-facing log stays unchanged.

## Concurrency / determinism

`uuidgen` is process-local randomness; two concurrent orchestrators in
different repos (same-repo concurrency is already a documented non-goal)
get distinct UUIDs. Claude Code requires `--session-id` to be unique per
active session; v4 UUID collision across two simultaneous dispatches is
negligible.

The diagnosis call is synchronous within `_dispatch_issue` — bounded by
a few git commands plus a tail of one JSONL file (≈100 ms vs. 5–15 min
of `claude -p` wall time). No timeout is set; if the helper hangs the
orchestrator hangs, but the helper has no network, no Linear calls, and
only local-FS reads.

## Files touched

- `skills/sr-start/scripts/orchestrator.sh` — three edits above.
- `skills/sr-start/scripts/diagnose_session.sh` — *new file*.
- `skills/sr-status/scripts/render_status.sh` — Done-loop sub-block.
- `docs/design/orchestrator.md` — `--session-id` flag, `progress.json`
  field reference (`session_id`, `transcript_path`, `hint`),
  diagnose-call mention.
- `docs/design/outcome-model.md` — operator-triage column updated for
  `failed` / `exit_clean_no_review` / `setup_failed` /
  `unknown_post_state` to mention the inline hint and transcript path.
- `docs/usage.md` — "What to expect in the morning" and "Checking
  progress mid-run" mention the inline hint and transcript path.
- `skills/sr-start/SKILL.md` — operator-triage bullet for `failed` /
  `exit_clean_no_review` updated to match `outcome-model.md`.
- `skills/sr-start/scripts/test/orchestrator.bats` — assert start
  records carry `session_id` + `transcript_path`; assert end records on
  the four eligible outcomes carry them; assert
  `setup_failed`/`local_residue`/`skipped` records do **not**.
- `skills/sr-status/scripts/test/render_status.bats` — fixture cases for
  hint+transcript+session sub-block on a `failed` row, and back-compat
  case for a record without the new fields.
- `skills/sr-start/scripts/test/diagnose_session.bats` — *new file*,
  fixture-driven coverage for each heuristic and composition.
- `docs/decisions/2026-04-28-session-diagnostics-A-C-E.md` — capture
  why we picked A+C+E over B/D, the heuristic-catalog choice
  (H1+H2+H3, deferring H4), and the JSONL defensive-parsing posture.

## Test fixtures

`skills/sr-start/scripts/test/fixtures/diagnose/` contains:

- A minimal JSONL transcript drawn from a real ENG-294-shaped session
  (PII scrubbed, three or four events: assistant turn with `Skill`
  tool_use, user tool_result, brief assistant text completion).
- An "implementation succeeded" JSONL fixture (no Skill in the tail).
- A malformed JSONL fixture (truncated mid-line) for the
  defensive-parsing path.
- A missing-JSONL case (no fixture file; the test passes a path that
  doesn't exist).

`diagnose_session.bats` cases:

1. Empty branch (no commits past base): H1 fires alone.
2. Commits + clean tree: no hints (empty stdout).
3. Commits + dirty tree: H2 fires alone.
4. Empty branch + dirty tree: H1 + H2 composed.
5. JSONL fixture (last turn = Skill + brief text), outcome=`failed`:
   H3 fires.
6. Same JSONL, outcome=`unknown_post_state`: H3 suppressed.
7. Same JSONL, outcome=`in_review`: script not invoked (orchestrator
   contract); test invokes anyway and asserts no output.
8. Missing JSONL, outcome=`failed`: H3 silently skipped (no error to
   stderr at default verbosity).
9. Malformed JSONL, outcome=`failed`: H3 silently skipped.
10. `RALPH_DIAGNOSE_DEBUG=1`: per-heuristic decisions appear on stderr.
11. Invalid `spec_base_sha`: H1 suppressed (git cat-file fails),
    H2 still runs.

## Acceptance criteria

1. **`progress.json` records carry the new fields.** A real `/sr-start`
   run produces start records with `session_id` and `transcript_path`,
   and end records on the four eligible outcomes carry both plus a
   conditionally-present `hint` field. `setup_failed`, `local_residue`,
   and `skipped` records do not include the session fields.

2. **`/sr-status` renders the diagnostic sub-block.** A `progress.json`
   containing a `failed` or `exit_clean_no_review` end record with
   `hint` + `transcript_path` + `session_id` renders the indented
   sub-block per the example above. `in_review` and `skipped` rows stay
   one-line. Records without the new fields render unchanged.

3. **`diagnose_session.sh` heuristics behave per the matrix.** Bats
   coverage for the cases above passes. Failure paths
   (missing/malformed JSONL, invalid spec-base-sha) silently suppress
   the affected heuristic; output remains either empty or correctly
   composed from surviving heuristics.

4. **Decision doc lands at `docs/decisions/`.** Captures the
   composition choice (A+C+E), the heuristic-catalog choice
   (H1+H2+H3, defer H4), and the JSONL defensive-parsing posture.

5. **Operator playbook updated.** `docs/usage.md`,
   `docs/design/outcome-model.md`, `docs/design/orchestrator.md`, and
   `skills/sr-start/SKILL.md` mention the inline hint and transcript
   path on the relevant operator-triage surfaces.

## Out of scope (explicit non-goals)

- **H4 (auto-mode refusal pattern).** Requires parsing claude-code's
  permission-denial JSONL schema, which is undocumented internal
  format. Higher coupling to claude-code internals than H1–H3; deferred
  pending observed need. Becomes a candidate follow-up issue if
  operators routinely encounter auto-mode refusals that the existing
  hints don't characterize.
- **B (auto-summarize via fast-claude).** Most ambitious; one extra
  fast-claude invocation per failed issue. Worth deferring until A+C+E
  is observed in operation.
- **D (`/sr-diagnose <issue-id>` operator command).** Self-paced
  deeper-inspection escape hatch. Pairs well with A; becomes a
  follow-up issue if the inline hints and transcript pointer prove
  insufficient.
- **End-to-end CI simulation of `exit_clean_no_review`.** The bats
  fixtures are the durable assertion. A live deliberately-crashed
  dispatch is useful for one-off validation but not as a CI artifact.
- **Backfilling `session_id` / `transcript_path` into legacy records.**
  Old records lack the fields; the renderer omits the missing pieces
  and the row degrades to today's behavior. No migration is needed.

## Prerequisites / blockers

**No `blocked-by` prerequisites.** All touched files exist and are
stable. ENG-307 (mitigates the most common cause of the cryptic-exit
shape) is `related`, not `blocked-by` — this work is useful even if
ENG-307 ships first or never. ENG-294 (the manifestation reference) is
already Done.

## References

- Manifestation: ENG-294 (2026-04-26 run; `exit_clean_no_review` →
  manual recovery).
- Related: ENG-307 (mitigates the most common cause of the
  cryptic-exit shape, but doesn't help with other failure modes).
- Upstream context-loss bug:
  [anthropics/claude-code#17351](https://github.com/anthropics/claude-code/issues/17351).
- Existing design: `docs/design/orchestrator.md` (dispatch loop,
  `progress.json` schema), `docs/design/outcome-model.md` (the seven
  outcomes), `docs/design/worktree-contract.md`
  (`.sensible-ralph-base-sha` ownership).
