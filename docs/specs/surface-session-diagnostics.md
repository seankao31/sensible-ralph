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
config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
slug="${path//\//-}"   # absolute worktree path with / → -
transcript_path="${config_dir}/projects/${slug}/${session_id}.jsonl"
```

`CLAUDE_CONFIG_DIR` is honored explicitly: when an operator has
relocated Claude Code's config directory, the orchestrator follows.
Fallback is `$HOME/.claude` (the documented default).

The slug rule (worktree absolute path with `/` → `-`) is **empirically
observed** by inspection of `~/.claude/projects/` on macOS and Linux
hosts running Claude Code 2.x; it is **not** a documented public
contract. Anthropic's docs describe the project directory name as a
"filesystem-safe encoding of the working directory," leaving the exact
encoding rule unspecified. The orchestrator dispatches via
`(cd $path; claude -p ...)` so cwd = worktree path; the slug is a pure
function of that path **as long as the encoding rule holds**.

Implications when the assumption breaks:
- A future Claude Code release that changes the encoding rule (e.g.
  introduces additional escaping for special characters) will cause
  `transcript_path` to point at a non-existent file. **Both the
  printed `session:` line in `/sr-status` and H3 (skill-context-loss
  detection) are affected** — H3 reads the same computed JSONL path
  and will silently suppress when the file is unreadable. The
  worktree-log path (`ralph-output.log`) and the H1/H2 git heuristics
  are independent of the slug rule and continue to work.
- The pointer is **not validated at write time** — the JSONL may not
  exist yet when the start record is written, and we don't want to
  pay an `[ -e ]` check on every dispatch.
- The pointer is **not validated at render time** in `/sr-status` — we
  print the path even if the file is missing, on the theory that a
  missing file is more useful diagnostically (the operator sees the
  intended location and can investigate) than no pointer at all.

A future ENG-N follow-up could harden this by reading the actual
session path via `--output-format stream-json` (one extra parse step
per dispatch); deferred pending observed need.

`transcript_path` is stored as an absolute path (not `~`-relative) so
copy-paste into a fresh shell works without depending on tilde
expansion.

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
  orchestrator stays the single source of truth. **Empty string is a
  valid value** and means "base-sha unavailable" — H1 must silently
  suppress in that case; H2 and H3 must still run.
- `<transcript_path>` — full absolute path the orchestrator computed.
  May not exist on disk; H3 handles missing/unreadable files
  defensively (silent suppression).

**Output:**

- stdout: zero or one line. The line is the composed hint. Heuristics
  are joined with `; ` when more than one fires. Empty match → no
  output (caller checks for empty string).
- stderr: silent at default verbosity. Per-heuristic decisions go to
  stderr only when `RALPH_DIAGNOSE_DEBUG=1`.
- Exit code: 0 on successful invocation (whether or not any heuristic
  fired); non-zero on misinvocation (see arg validation below). A
  failed individual heuristic is silently dropped, not propagated.

**Argument validation (non-zero exit on failure):**

- `outcome` must be non-empty and one of the seven outcome strings.
- `worktree_path` must be non-empty.
- `spec_base_sha` may be empty (documented sentinel; H1 suppresses).
  Any other value is treated as a candidate SHA and fed to git.
- `transcript_path` must be non-empty.

On any of these validation failures, the helper exits non-zero and
writes a diagnostic to stderr describing which arg failed validation
(`diagnose_session: missing required arg <name>`). The orchestrator
must treat a non-zero exit as "no hint produced" and proceed with the
end-record write — argument-validation errors are an implementation
defect to surface (visible in the orchestrator's stderr), not a
silent-failure path that suppresses observability.

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

- **H1-nocommits** (always-on for eligible outcomes when
  `spec_base_sha` is non-empty). `git rev-list
  "$spec_base_sha"..HEAD --count` on the worktree branch. When 0,
  emit `no implementation commits`. Validate `spec_base_sha` exists
  (`git cat-file -e "$spec_base_sha^{commit}"`) before counting; on
  validation failure or empty `spec_base_sha`, suppress the heuristic.
  H1 is the only heuristic that consults `spec_base_sha`; H2 and H3
  must run regardless of its presence.

- **H2-dirtytree** (always-on for eligible outcomes). `git status
  --porcelain` non-empty → emit `uncommitted edits left in worktree`.

  **Exclude orchestrator-owned files** before emitting. The
  orchestrator writes `${CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME}`
  (default `ralph-output.log`) and `.sensible-ralph-base-sha` into the
  worktree as part of normal dispatch. The repo's `.gitignore`
  ignores both at their default names, but operators can override
  `stdout_log_filename` via plugin config; an operator who renames
  without updating their repo's `.gitignore` would see false-positive
  H2 hints on every run. The implementation must filter out paths
  matching either filename from the porcelain output before deciding
  whether to fire — for example, by piping through
  `grep -vE "^.. (\.sensible-ralph-base-sha|${CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME})$"`
  or equivalent. After filtering, fire only if at least one line
  remains.

- **H3-skill-context-loss** (gated to `failed` /
  `exit_clean_no_review` only). Defensive JSONL parsing: read up to
  the last 5 events whose `type == "assistant"`. Fire if (a) at least
  one of those events contains a tool_use whose `name == "Skill"`, AND
  (b) no chronologically-later event in the window contains any
  tool_use. Emit `context-loss after Skill (<skill-name>)
  (claude-code#17351)`.

  **Bounded poll for JSONL readiness:** Claude Code's JSONL flush
  timing relative to `claude -p` process exit is undocumented; in
  practice the file may not be fully materialized for a brief window
  after exit. Before reading, H3 polls for `transcript_path`
  readability up to 20 times at 100 ms intervals (≤ 2 s total). On
  the common case (file already present) the poll exits on first
  iteration. On true absence (slug-rule mismatch, or claude-code
  didn't write the file at all) the poll exhausts and the heuristic
  silently suppresses. When `RALPH_DIAGNOSE_DEBUG=1` is set, the
  helper emits `H3: transcript_path not ready after 2s — suppressing`
  to stderr so operators can distinguish a flush race from a genuine
  no-match. The 2 s budget is per dispatched non-success outcome only
  (not on every dispatch), and is dwarfed by the 5–15 min `claude -p`
  wall time.

  JSONL parsing posture: **defensive, suppress on uncertainty.** If
  the JSONL is missing after the bounded poll, unreadable, or any
  `jq` access errors, the heuristic is silently suppressed. If a
  future Claude Code release changes the JSONL schema (which is
  undocumented internal format), the heuristic stops firing rather
  than emitting wrong hints. This trade-off — under-report rather
  than mis-report — is the explicit design choice for JSONL-dependent
  heuristics.

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
existing one-line row, render an indented sub-block driven entirely
by **field presence**, with one whole-sub-block override for
`in_review`.

```
  ENG-294  exit_clean_no_review      14m
    ↳ no implementation commits; context-loss after Skill (using-superpowers) (claude-code#17351)
      transcript: <worktree_log_path>
      session: <transcript_path>
```

**The single rule:** for each Done row, the renderer attempts to emit
three sub-block lines. Each line is gated on the presence and
non-emptiness of one specific record field — no outcome-name checks.

| Line | Gate (single condition, no other checks) |
|---|---|
| `↳ <hint>` | `record.hint` present and non-empty |
| `transcript: <worktree_log_path>` | `record.worktree_log_path` present and non-empty; printed verbatim, no reconstruction |
| `session: <transcript_path>` | `record.transcript_path` present and non-empty |

If **all three** gates fail, no sub-block is emitted — the row stays
one-line. There is no outcome allowlist, no per-outcome reasoning, no
fallback reconstruction. A record that doesn't carry the field doesn't
get the line.

**Whole-sub-block override for `in_review`:** the only outcome-named
rule. Even if an `in_review` end record carries `worktree_log_path` and
`transcript_path` (which it will), the renderer suppresses the entire
sub-block on `in_review` rows. Successful rows stay one-line for
scannability; operators don't need diagnostic plumbing on green
outcomes. This is the only place outcome name appears in the renderer
contract.

**Consequences (worked through, not enforced by code):**
- `failed` / `exit_clean_no_review` / `unknown_post_state`: all three
  fields are populated by the orchestrator → all three lines render.
- `in_review`: fields are populated but the whole-sub-block override
  fires → row stays one-line.
- `setup_failed`, `local_residue`, `skipped`: orchestrator does not
  populate the three fields per Section 2's schema → all three gates
  fail → row stays one-line via field-absence.
- Legacy records (pre-this-change): same as `setup_failed` —
  field-absence keeps the row one-line. Back-compat is automatic; no
  migration needed.

`↳` is U+21B3 — emitted as the UTF-8 byte sequence `\xe2\x86\xb3`
(`printf '\xe2\x86\xb3'`) so the renderer doesn't depend on the source
file's encoding being preserved through editing tools.

The `transcript:` line is the worktree log path (`ralph-output.log`),
not the JSONL — operators get both, with the worktree log being the
faster glance and the session JSONL being the deep-dive option.

**Footer "Tip: tail …" for the in-flight Running row** also switches
to the persisted `worktree_log_path` from the matching start record.
The current renderer rebuilds this path from
`CLAUDE_PLUGIN_OPTION_WORKTREE_BASE` + `CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME`
+ the record's `branch`, which exhibits the same live-config drift
problem as the Done-row reconstruction did. Reading
`worktree_log_path` directly from the running issue's start record
keeps the tip accurate after config changes mid-run. When the start
record lacks `worktree_log_path` (legacy run from before this change),
fall back to the current live-config reconstruction so the footer
keeps rendering something useful.

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
- **Value:** `<config_dir>/projects/<slug>/<session_id>.jsonl` where
  `<config_dir>` is `CLAUDE_CONFIG_DIR` if set and absolute, else
  `$HOME/.claude`. Stored as absolute path; a non-absolute
  `CLAUDE_CONFIG_DIR` is rejected (with a stderr warning) and the
  default is used instead — see the orchestrator wiring below for the
  exact validation.
- **Not validated for file existence at write time** (the JSONL may
  not exist yet when the start record is written).

### `worktree_log_path`
- **Where:** same records as `session_id` (start records and
  dispatched-outcome end records).
- **Value:** absolute path to the per-session stdout log file as it
  existed *at dispatch time* —
  `${path}/${CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME}` resolved during
  dispatch and persisted into the record. Stored verbatim so historical
  rows keep pointing at the right file even if
  `CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME` or
  `CLAUDE_PLUGIN_OPTION_WORKTREE_BASE` is later reconfigured.
- **Why persisted (not recomputed):** the renderer was previously
  expected to reconstruct this path from current config + the record's
  `branch`. Live-config reconstruction would render a plausible-but-wrong
  path for historical rows after a config change — a silent diagnostic
  misdirection that's hard to notice in failure recovery. Persisting
  the dispatch-time path makes the record self-contained.

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
  "worktree_log_path": "/Users/seankao/Workplace/Projects/sensible-ralph/.worktrees/eng-294-write-docsdesignorchestratormd/ralph-output.log",
  "hint": "no implementation commits; context-loss after Skill (using-superpowers) (claude-code#17351)"
}
```

## Orchestrator wiring

Three edits to `skills/sr-start/scripts/orchestrator.sh`, all confined
to `_dispatch_issue` and the start/end record-emission paths.

### Edit 1 — pre-generate `session_id`, compute `transcript_path` and `worktree_log_path`

Inserted after `path` is resolved (line ~395 region) and before the
start-record write. Done once per issue and reused for both records.

```bash
local session_id; session_id="$(uuidgen | tr 'A-Z' 'a-z')"

# Resolve config_dir, distinguishing unset from empty so we can warn
# explicitly on an empty value (a misconfiguration) without warning
# on the common unset case (the documented default path).
#
# `${VAR-default}` (no colon) substitutes default ONLY when VAR is
# unset; `${VAR:-default}` substitutes for both unset AND empty.
# We need to differentiate, so we use the no-colon form and handle
# empty separately.
local config_dir
if [[ -z "${CLAUDE_CONFIG_DIR+set}" ]]; then
  # CLAUDE_CONFIG_DIR is unset — silent default.
  config_dir="$HOME/.claude"
elif [[ -z "$CLAUDE_CONFIG_DIR" ]]; then
  # CLAUDE_CONFIG_DIR is set but empty — likely misconfiguration.
  printf 'orchestrator: CLAUDE_CONFIG_DIR is set but empty; falling back to $HOME/.claude\n' >&2
  config_dir="$HOME/.claude"
else
  config_dir="$CLAUDE_CONFIG_DIR"
fi

# Require absolute path. Relative values would resolve differently in
# the orchestrator's cwd vs. /sr-status's cwd vs. the helper's cwd,
# and would silently misdirect H3 and the rendered session: line.
case "$config_dir" in
  /*) ;;
  *)
    printf 'orchestrator: CLAUDE_CONFIG_DIR=%q is not absolute; falling back to $HOME/.claude\n' \
      "$config_dir" >&2
    config_dir="$HOME/.claude"
    ;;
esac

local slug; slug="${path//\//-}"
local transcript_path="${config_dir}/projects/${slug}/${session_id}.jsonl"
local worktree_log_path="${path}/${CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME}"
```

`$path` is the worktree absolute path (already absolute by orchestrator
construction), so `worktree_log_path` is guaranteed absolute when the
orchestrator's existing path-resolution invariants hold.

`worktree_log_path` is captured at dispatch time and persisted into both
records so the renderer never reconstructs from live config. Renaming
`CLAUDE_PLUGIN_OPTION_WORKTREE_BASE` or
`CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME` between dispatch and triage
must not silently misdirect operators to a non-existent log path.

### Edit 2 — thread fields into start record + claude invocation

Existing start-record write gets three `--arg` additions and three new
keys in the `jq` body:

```bash
start_record="$(jq -n \
  --arg issue "$issue_id" \
  --arg branch "$branch" \
  --arg base "$base_out" \
  --arg ts "$dispatch_timestamp" \
  --arg run "$run_id" \
  --arg sid "$session_id" \
  --arg tp "$transcript_path" \
  --arg wlp "$worktree_log_path" \
  '{event: "start", issue: $issue, branch: $branch, base: $base,
    timestamp: $ts, run_id: $run, session_id: $sid,
    transcript_path: $tp, worktree_log_path: $wlp}')"
```

Existing dispatch invocation gains one flag and an env-var override:

```bash
CLAUDE_CONFIG_DIR="$config_dir" claude -p \
  --permission-mode auto \
  --model "$CLAUDE_PLUGIN_OPTION_MODEL" \
  --name "$issue_id: $title" \
  --session-id "$session_id" \
  "$prompt" \
  2>&1 | tee "$path/$CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME"
```

The `CLAUDE_CONFIG_DIR="$config_dir"` prefix forces the subprocess to
use the **same** config directory the orchestrator just normalized.
Without this, an empty/relative `CLAUDE_CONFIG_DIR` set in the parent
shell would cause the orchestrator to record one path while claude
writes the JSONL elsewhere (or fails with a config error). With it,
the recorded `transcript_path` and the actual JSONL location stay in
sync regardless of caller-side misconfiguration.

### Edit 3 — invoke `diagnose_session.sh` and thread hint through both control-flow paths

Inserted **before** the existing
`if [[ "$claude_exit" -eq 0 && "$state_fetch_ok" -eq 0 ]]` early-return
that calls `_record_unknown_post_state`. The current orchestrator
flow is:

```
classify post_state / state_fetch_ok
  if claude_exit == 0 && state_fetch_ok == 0:
    _record_unknown_post_state ...; return 0   # ← early return
  classify outcome (in_review | exit_clean_no_review | failed)
  apply ralph-failed / taint as needed
  write end record (the jq -n block)
```

**Move the outcome derivation up** so a single computed `outcome`
variable is available before the early-return decision, and compute
`hint` in one place that runs for all three dispatched non-success
outcomes:

```bash
# Compute outcome FIRST (was inline below; promote so unknown_post_state
# also benefits from the diagnose call without duplicating logic).
local outcome
if [[ "$claude_exit" -eq 0 && "$state_fetch_ok" -eq 0 ]]; then
  outcome="unknown_post_state"
elif [[ "$claude_exit" -eq 0 && "$post_state" == "$CLAUDE_PLUGIN_OPTION_REVIEW_STATE" ]]; then
  outcome="in_review"
elif [[ "$claude_exit" -eq 0 ]]; then
  outcome="exit_clean_no_review"
else
  outcome="failed"
fi

# Compute hint once for all three dispatched non-success outcomes. The
# spec-base-sha is read from <path>/.sensible-ralph-base-sha (written
# pre-dispatch per docs/design/worktree-contract.md).
local hint=""
case "$outcome" in
  exit_clean_no_review|failed|unknown_post_state)
    local spec_base_sha=""
    if [[ -r "$path/.sensible-ralph-base-sha" ]]; then
      spec_base_sha="$(cat "$path/.sensible-ralph-base-sha")"
    fi
    # Always invoke diagnose, even if base-sha is missing/blank. The
    # helper handles per-heuristic suppression: H1 silently skips on
    # invalid spec_base_sha, while H2 and H3 proceed independently.
    # Gating the whole call on base-sha presence would create a hidden
    # single point of failure for the entire diagnostic path.
    #
    # Stderr handling: by default we let helper stderr through to the
    # orchestrator's stderr, so RALPH_DIAGNOSE_DEBUG=1 breadcrumbs (and
    # any argument-validation errors) surface to the operator. Helper
    # is silent at default verbosity, so this isn't noisy in the
    # common path.
    # Bound the helper with a hard timeout (5 s budget) so a hung
    # heuristic cannot block failure bookkeeping (label writes, taint
    # propagation, end-record write). Diagnostic output is best-effort;
    # critical-path side effects must always run. On timeout, hint stays
    # empty and the orchestrator proceeds.
    #
    # `timeout` (GNU coreutils) is on every Linux box and via Homebrew
    # on macOS as `gtimeout`. Detect at invocation time and degrade
    # to a no-timeout call with a one-time stderr note when neither
    # is present. This is acceptable degradation: H3's own bounded
    # poll already caps it at 2 s, and H1/H2 are bounded by physics
    # (a few git commands).
    local timeout_cmd=""
    if command -v timeout >/dev/null 2>&1; then
      timeout_cmd="timeout 5"
    elif command -v gtimeout >/dev/null 2>&1; then
      timeout_cmd="gtimeout 5"
    else
      printf 'orchestrator: timeout/gtimeout not available; running diagnose unbounded (H3 self-caps at 2s)\n' >&2
    fi
    # Helper stderr passes through to the orchestrator's stderr by
    # contract (silent at default verbosity, breadcrumbs only when
    # RALPH_DIAGNOSE_DEBUG=1). Never blanket-redirect.
    hint="$($timeout_cmd bash "$SCRIPT_DIR/diagnose_session.sh" \
      "$outcome" "$path" "$spec_base_sha" "$transcript_path")" || hint=""
    ;;
esac

# Branch on outcome for Linear-mutation side effects + which record
# helper to call. Both branches receive the same hint.
if [[ "$outcome" == "unknown_post_state" ]]; then
  _record_unknown_post_state "$issue_id" "$branch" "$base_out" \
    "$claude_exit" "$duration" "$dispatch_timestamp" \
    "$session_id" "$transcript_path" "$worktree_log_path" "$hint"
  return 0
fi

# in_review / exit_clean_no_review / failed take the existing end-record path
case "$outcome" in
  exit_clean_no_review|failed)
    linear_add_label "$issue_id" "$CLAUDE_PLUGIN_OPTION_FAILED_LABEL" || \
      printf 'orchestrator: failed to add %s label to %s (continuing)\n' \
        "$CLAUDE_PLUGIN_OPTION_FAILED_LABEL" "$issue_id" >&2
    _taint_descendants "$issue_id"
    ;;
esac
```

The diagnose call is wrapped in a 5-second `timeout`/`gtimeout` budget
so a hung heuristic cannot block failure bookkeeping. On timeout,
`hint` stays empty and the orchestrator proceeds with `linear_add_label`,
`_taint_descendants`, and the end-record write. Critical-path side
effects always run; diagnostic augmentation is best-effort. When
neither `timeout` nor `gtimeout` is available, the helper runs
unbounded with a one-time stderr note — H3's own internal 2-second
poll cap is the second line of defense; H1/H2 are bounded by physics.

The empty-sentinel for `spec_base_sha` is part of `diagnose_session.sh`'s
contract: when the third positional arg is empty, H1 is suppressed
(documented in the helper's invocation contract above). H2 and H3 do
not consult `spec_base_sha` and proceed regardless.

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
  --arg wlp "$worktree_log_path" \
  --arg hint "$hint" \
  '{event: "end", issue: $issue, branch: $branch, base: $base, outcome: $outcome,
    exit_code: $exit_code, duration_seconds: $duration, timestamp: $ts,
    run_id: $run, session_id: $sid, transcript_path: $tp,
    worktree_log_path: $wlp}
   + (if $hint == "" then {} else {hint: $hint} end)')"
```

The `+ (if $hint == "" then {} else {hint: $hint} end)` idiom keeps the
field absent (not empty) when no heuristic fires.

`_record_unknown_post_state`'s signature is extended to accept
`session_id`, `transcript_path`, `worktree_log_path`, and `hint` (it
currently takes six positional args; this becomes ten). The body
emits with the same conditional-presence idiom as the inline end-record
write: include `hint` only when non-empty, include the three new path
fields unconditionally (they're always non-empty when the helper is
called from the dispatch path). The illustrative end record's
`worktree_log_path` and `hint` fields appear on `unknown_post_state`
records exactly the same as on `failed`/`exit_clean_no_review` —
the renderer's per-line gates rely on this. `_record_setup_failure`
and `_record_local_residue` remain unchanged — they don't get
`session_id` fields per the schema above, and they're not invoked
from the dispatch-time control flow that computes `hint`.

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

The diagnosis call is synchronous within `_dispatch_issue` and **hard
bounded** by the 5-second `timeout`/`gtimeout` wrapper described in
Edit 3 above. When neither `timeout` nor `gtimeout` is available, the
helper runs unbounded with a one-time stderr note; in that degraded
mode H3's own internal 2-second poll cap remains in place, and H1/H2
are bounded by physics (a few git commands, ~100 ms worst case). The
authoritative timeout contract lives in Edit 3; this section is the
operator-facing summary.

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
  records carry `session_id` + `transcript_path` + `worktree_log_path`;
  assert end records on the four eligible outcomes (including
  `unknown_post_state`) carry all three; assert
  `setup_failed`/`local_residue`/`skipped` records do **not**; assert
  `transcript_path` honors `CLAUDE_CONFIG_DIR` when set to an absolute
  path, falls back to `$HOME/.claude` when unset, falls back to
  `$HOME/.claude` (with stderr warning) when set to an empty string,
  and falls back to `$HOME/.claude` (with stderr warning) when set to
  a relative path; assert `worktree_log_path` is the dispatch-time
  absolute path even when `CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME`
  is changed between dispatch and a follow-up render; assert the
  diagnose helper is invoked with empty `spec_base_sha` when
  `.sensible-ralph-base-sha` is missing (and not gated out).
- `skills/sr-status/scripts/test/render_status.bats` — fixture cases for
  hint+transcript+session sub-block on a `failed` row; back-compat case
  for a record without the new fields (sub-block lines suppressed
  individually); per-line suppression cases (record with `hint` but no
  `worktree_log_path`/`transcript_path`, record with
  `worktree_log_path` but no `hint`, `setup_failed` record stays
  one-line, `in_review` record stays one-line even when fields are
  present); assert `transcript:` line uses the persisted
  `worktree_log_path` verbatim and is **not** affected by changing
  `CLAUDE_PLUGIN_OPTION_STDOUT_LOG_FILENAME` at render time.
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
8. Missing JSONL, outcome=`failed`: H3 silently skipped after the
   bounded poll exhausts (no error to stderr at default verbosity).
9. Malformed JSONL, outcome=`failed`: H3 silently skipped.
9b. JSONL appears mid-poll (created at t=500 ms, well within the 2 s
    budget): H3 reads it on a subsequent poll iteration and fires
    normally. Verifies the bounded-poll behavior, not just the
    file-already-present and file-never-appears extremes.
10. `RALPH_DIAGNOSE_DEBUG=1`: per-heuristic decisions appear on
    stderr, including the
    `H3: transcript_path not ready after 2s — suppressing` line when
    the bounded poll exhausts.
11. Invalid `spec_base_sha` (well-formed but unknown SHA): H1
    suppressed (git cat-file fails), H2 still runs.
12. Empty `spec_base_sha` (orchestrator passed `""` because
    `.sensible-ralph-base-sha` was unreadable): H1 suppressed without
    even attempting `git cat-file`, H2 and H3 still run.

## Acceptance criteria

1. **`progress.json` records carry the new fields.** A real `/sr-start`
   run produces start records with `session_id`, `transcript_path`, and
   `worktree_log_path`. End records on the four eligible outcomes carry
   all three plus a conditionally-present `hint` field.
   `setup_failed`, `local_residue`, and `skipped` records do not
   include the session fields. `transcript_path` honors
   `CLAUDE_CONFIG_DIR` when set; falls back to `$HOME/.claude` otherwise.
   `worktree_log_path` is captured at dispatch time and persisted
   verbatim — never reconstructed from live config at render time.

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
