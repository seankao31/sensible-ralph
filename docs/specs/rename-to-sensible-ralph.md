# Rename ralph to sensible-ralph across plugin surfaces

**Linear:** ENG-276
**Status:** Approved
**Project:** Sensible Ralph
**Date:** 2026-04-25

Align plugin-identity surfaces with the actual plugin name
(`sensible-ralph`). Heritage references — "vanilla ralph" narrative, the
ralph technique citation, external fork links, archived design records,
and verb-noun usages like the `ralph-failed` label — stay as `ralph`.

## Motivation

The plugin's name is `sensible-ralph`, and the marketplace and manifest
already say so. But several plugin-mechanic surfaces (consumer scope
file, internal env vars, slash commands, skill directories, per-worktree
markers) still carry the heritage `ralph` token from before the
extraction. This ticket aligns identity-bearing surfaces with the actual
plugin name while preserving heritage references the operator should
keep recognizing.

## Renaming principle

- **Plugin identity** (names *this implementation*) → rename.
- **Verb-noun heritage** (describes what "the ralph dispatcher" does or
  produces — e.g. `ralph-failed`, `ralph-output.log`) → stay as `ralph-`.
- **Technique-class references** (vanilla ralph narrative, the technique
  citation, external forks, archived design records) → stay.

## Surface map

| # | Surface | Today | After |
|---|---|---|---|
| 1 | Consumer scope file (repo root, tracked) | `.ralph.json` | `.sensible-ralph.json` |
| 2 | Main-checkout subsystem dir (gitignored, runtime) | `.ralph/` | `.sensible-ralph/` |
| 3 | Per-worktree base-SHA marker | `.ralph-base-sha` | `.sensible-ralph-base-sha` |
| 4 | Internal env vars | `RALPH_PROJECTS`, `RALPH_SCOPE_LOADED` | `SENSIBLE_RALPH_PROJECTS`, `SENSIBLE_RALPH_SCOPE_LOADED` |
| 5 | Slash commands | `/ralph-{start,spec,implement,status}` | `/sr-{start,spec,implement,status}` |
| 6 | Skill directories | `skills/ralph-{start,spec,implement,status}/` | `skills/sr-{start,spec,implement,status}/` |
| H1 | Default `failed_label` | `ralph-failed` | **stays heritage** (verb-noun) |
| H2 | Default `stdout_log_filename` | `ralph-output.log` | **stays heritage** (verb-noun) |
| H3 | Per-worktree stdout log | `ralph-output.log` | **stays heritage** (follows H2) |

The plugin name in `.claude-plugin/plugin.json` and
`.claude-plugin/marketplace.json` is already `sensible-ralph` — no edit.

The `sr-` prefix on slash commands and skill directories is the chosen
compromise between bare `/start` (collision-prone, requires plugin
namespacing to disambiguate) and full `/sensible-ralph-start` (mouthful
at the call site). Env vars use the full `SENSIBLE_RALPH_` prefix
because env vars conventionally favor descriptive names
(`LD_LIBRARY_PATH`, `KUBECONFIG`, `XDG_CONFIG_HOME`) and the "short for
typing" rationale doesn't apply to identifiers nobody types at a
prompt.

## In scope

One atomic commit covering all six rename categories. Implementer's
loop:

1. **Inventory** all references:
   ```bash
   grep -rEn '\bralph|RALPH_' \
     --include='*.md' --include='*.sh' --include='*.json' --include='*.bats' \
     . 2>/dev/null \
     | grep -v 'docs/archive/\|\.git/\|\.worktrees/'
   ```
   The `\bralph` pattern catches every token starting with `ralph`
   after a word boundary — `ralph-spec`, `.ralph.json`, `/.ralph/`,
   `vanilla ralph`, `snarktank/ralph`. The implementer's job at
   inventory time is to *see all of these* and then filter heritage
   manually. (The narrower acceptance grep below excludes heritage by
   construction.)
2. **Filter** heritage carve-outs (see Out of scope).
3. **Sweep** one surface category at a time.
4. **Re-grep** to verify only heritage hits remain.

### Category 1 — Consumer scope file (`.ralph.json` → `.sensible-ralph.json`)

Roughly 68 path hits across the repo. Affected files:

- `README.md` — Prerequisites section (the JSON-shape example block) and
  any narrative references.
- `docs/usage.md` — frequent narrative mentions; the
  "out-of-scope blocker" anomaly description points at the file as the
  fix.
- `skills/sr-start/SKILL.md`,
  `skills/sr-spec/SKILL.md`,
  `skills/sr-implement/SKILL.md`,
  `skills/prepare-for-review/SKILL.md`,
  `skills/close-issue/SKILL.md`.
- `skills/sr-start/scripts/lib/scope.sh` — the loader; multiple
  references in code and comments.
- `skills/sr-start/scripts/lib/defaults.sh` — if it mentions the file.
- `skills/sr-start/scripts/orchestrator.sh`,
  `build_queue.sh`,
  `dag_base.sh`,
  `preflight_scan.sh` — caller comments and any path references.
- `skills/sr-start/scripts/test/*.bats` — fixture setup that creates
  the scope file in test repos.

Skip: `docs/archive/`, the three `docs/specs/*-design.md` records, this
spec file's own references to the old name (allowed; excluded from the
acceptance grep).

### Category 2 — Main-checkout subsystem dir (`.ralph/` → `.sensible-ralph/`)

The directory ENG-255 introduces. Touch points:

- `.gitignore` (plugin's own template) — entry `/.ralph/` →
  `/.sensible-ralph/`. The `/.worktrees/` and `ralph-output.log` lines
  are unchanged.
- `README.md` — consumer-repo gitignore example block in Prerequisites,
  matching the plugin's own `.gitignore`.
- `docs/usage.md` — narrative references to the dir and its contents.
- `skills/sr-start/SKILL.md` — `.ralph/progress.json` and
  `.ralph/ordered_queue.txt` paths in steps 2 and 4.
- `skills/sr-start/scripts/orchestrator.sh` — `mkdir -p
  "$repo_root/.ralph"` line and `local progress_file="$repo_root/.ralph/progress.json"`. Header comment line referencing the dir.
- `skills/sr-start/scripts/build_queue.sh` — usage comment.
- `skills/sr-start/scripts/test/orchestrator.bats` — ~36 path
  expressions like `$REPO_DIR/.ralph/progress.json`.
- Any stragglers in `skills/close-issue/SKILL.md`,
  `skills/prepare-for-review/SKILL.md`,
  `skills/sr-implement/SKILL.md` — only edit on grep hits.

### Category 3 — Per-worktree base-SHA marker (`.ralph-base-sha` → `.sensible-ralph-base-sha`)

Affected files:

- `skills/sr-start/scripts/orchestrator.sh` — writer (where the
  orchestrator records the base SHA at worktree creation).
- `skills/prepare-for-review/SKILL.md` — reader (`if .ralph-base-sha
  exists` block).
- `skills/sr-implement/SKILL.md` — narrative mention of the file.
- `README.md` — the operator-migration cleanup note (introduced by
  ENG-255) referencing `.ralph-base-sha`.
- `skills/sr-start/scripts/test/*.bats` — any test setup that touches
  the file.

### Category 4 — Internal env vars (`RALPH_PROJECTS`, `RALPH_SCOPE_LOADED` → `SENSIBLE_RALPH_*`)

Roughly 22 hits. Affected files:

- `skills/sr-start/scripts/lib/scope.sh` — variable declarations,
  `export` lines, and comments.
- `skills/sr-start/scripts/orchestrator.sh`,
  `build_queue.sh`,
  `dag_base.sh`,
  `preflight_scan.sh` — caller usage and `EXPECTED_SCOPE_LOADED`
  comparison guards.
- `skills/sr-spec/SKILL.md` — the finalize step (`source
  scope.sh`/`RALPH_PROJECTS` references).
- `skills/close-issue/SKILL.md` — `resolve_branch_for_issue` context
  and any other usage.
- `skills/sr-start/scripts/test/*.bats` — test setup that exports the
  env var.

If `RALPH_LIB` or any other `RALPH_*` identifier exists in current code,
rename in lockstep. If found only in design-record specs (heritage),
leave alone.

### Category 5 — Slash commands and skill directories

Four `git mv` operations:

- `skills/ralph-start/` → `skills/sr-start/`
- `skills/ralph-spec/` → `skills/sr-spec/`
- `skills/ralph-implement/` → `skills/sr-implement/`
- `skills/ralph-status/` → `skills/sr-status/`

Then update slash-command references in:

- `README.md` — the Brief summary (lists `/ralph-start`, `/ralph-spec`,
  `/ralph-implement`, `/ralph-status`) and Design notes
  (`disable-model-invocation` callout names them).
- `docs/usage.md` — multiple narrative mentions, including the
  "Checking progress mid-run" section that documents `/ralph-status`.
- `skills/close-issue/SKILL.md`,
  `skills/prepare-for-review/SKILL.md` — cross-references.
- `skills/sr-start/SKILL.md`,
  `skills/sr-spec/SKILL.md`,
  `skills/sr-implement/SKILL.md`,
  `skills/sr-status/SKILL.md` — self- and cross-references in their
  own narratives, including the `name:` frontmatter field on each
  SKILL.md and the user-facing `"ralph-status: …"` error strings in
  `skills/sr-status/scripts/render_status.sh` (they name the command,
  not the dispatcher).
- `skills/sr-start/scripts/test/*.bats`,
  `skills/sr-status/scripts/test/*.bats` — any references to skill
  directory paths or to the command name in test descriptions.

The `sr-spec` skill's own checklist refers to itself as `/ralph-spec`
in places — update to `/sr-spec`. Same for `sr-start`, `sr-implement`,
and `sr-status`.

This category has the largest path-hit count because every reference
to a skill directory file (`skills/ralph-start/scripts/lib/...`)
contains the old name. Use `git mv` for the four top-level dir
renames; the path references update in code/markdown via the same
sweep.

## Out of scope

- **Heritage references stay**: vanilla ralph narrative, the technique
  citation (Geoff Huntley's original), snarktank/ralph and
  frankbria/ralph-claude-code fork links — by ticket carve-out.
- **Verb-noun heritage stays**: `ralph-failed` label default
  (`failed_label` userConfig) and `ralph-output.log` filename default
  (`stdout_log_filename` userConfig). Consumers who overrode the
  default at install time keep their override; new installs continue
  getting the heritage default.
- **Archived docs**: `docs/archive/**` — point-in-time records, not
  touched.
- **Design records** in `docs/specs/`: `ralph-loop-v2-design.md`,
  `ralph-implement-skill-design.md`,
  `ralph-scope-model-design.md` — historical decision documents named
  for vanilla ralph at the time of writing.
- **Spec filenames containing `ralph`**: e.g.,
  `ralph-status-command.md`,
  `2026-04-25-ralph-start-default-base-branch.md`,
  `2026-04-25-codex-review-gate-in-ralph-spec.md`. The spec *files* are
  point-in-time records — keep the filenames as-is. But inside those
  spec files, rename **any mention** of current plugin mechanics or
  callable surfaces — including command names, skill directory paths,
  env vars, runtime filenames, and diagram node identifiers — in both
  code-formatted and plain prose. Examples: `/ralph-spec` → `/sr-spec`,
  `skills/ralph-start/` → `skills/sr-start/`, `RALPH_PROJECTS` →
  `SENSIBLE_RALPH_PROJECTS`, `digraph ralph_spec {` → `digraph sr_spec
  {`. Only the spec filename itself (used as a path reference or link
  target in another file) stays unchanged.
- **Marketplace and plugin manifest**: `.claude-plugin/marketplace.json`
  and `.claude-plugin/plugin.json` already say `sensible-ralph`. The
  `failed_label` and `stdout_log_filename` userConfig defaults
  unchanged.
- **No backward-compat shim** for `.ralph.json` lookup, `RALPH_*` env
  vars, or old slash command names. Pre-1.0 plugin; consumers run the
  migration ritual.
- **Schema/shape changes** to the scope file, `progress.json`, or
  `ordered_queue.txt` — out of scope; this is a rename only.

## Implementer self-modification edge case

This rename's autonomous session runs *under* the cached old-version
plugin. Inside the session:

- The cached `orchestrator.sh` (operating from
  `~/.claude/plugins/cache/`) writes `.ralph-base-sha` at the worktree
  root *before* invoking the session.
- The cached `/prepare-for-review` will read it under the old name when
  the session ends.
- The implementer changes *code* (renaming references), not runtime
  files in the worktree root.
- Bats tests in the worktree run against the *new* code and use the
  new names — that's correct under test.

So: **don't rename or delete the runtime `.ralph-base-sha` file at the
worktree root during the task** — only update its name in source code
references. The cached plugin needs the old-name file at the worktree
root to complete the session; if it's missing, `prepare-for-review`
will fall back to the wrong base SHA.

Note on the acceptance grep: criterion 1's grep scans only
`*.md`, `*.sh`, `*.json`, and `*.bats` files — the extensionless
runtime `.ralph-base-sha` at the worktree root is NOT scanned. When
the grep surfaces `.ralph-base-sha` hits (e.g., from
`orchestrator.sh` or `prepare-for-review/SKILL.md`), those are
source-code references that **do** rename. The runtime file is exempt
and must still be present at completion (see acceptance criterion 9).

The same logic applies to `.ralph/progress.json` at the operator's
main-checkout root: leave it alone; the operator migration moves it.

## Migration ritual (operator-side, post-merge)

After this ticket merges and the operator pulls into the consumer
repo, run once at the consumer repo root:

```bash
# Rename the consumer scope file
git mv .ralph.json .sensible-ralph.json

# Move the runtime artifacts dir if it exists from prior runs
mv .ralph/ .sensible-ralph/ 2>/dev/null || true

# In-flight worktrees: stale base-SHA markers can be removed
# (re-derive on next session)
find .worktrees -maxdepth 2 -name '.ralph-base-sha' -delete 2>/dev/null || true
```

Slash-command muscle memory just retrains — no file action.

The README's consumer-repo gitignore example block (currently `/.ralph/`,
`/.worktrees/`, `ralph-output.log` after ENG-255 lands) updates to:

```gitignore
/.sensible-ralph/
/.worktrees/
ralph-output.log
```

`ralph-output.log` stays heritage; consumers with overridden
`stdout_log_filename` keep their override.

## Acceptance criteria

1. **No `ralph` plugin-identity hits remain** outside heritage carve-outs.
   This grep returns only heritage:
   ```bash
   grep -rEn '(\.ralph\b|\.ralph[-/]|\bRALPH_[A-Z_]+|\bralph-(start|spec|implement|status)\b|\bralph_[a-z]|skills/ralph-)' \
     --include='*.md' --include='*.sh' --include='*.json' --include='*.bats' \
     . 2>/dev/null \
     | grep -v 'docs/archive/\|\.git/\|\.worktrees/' \
     | grep -v 'docs/specs/.*-design\.md' \
     | grep -v 'docs/specs/rename-to-sensible-ralph\.md'
   ```
   Pattern notes: `\.ralph` and `skills/ralph-` are path-anchored and
   need no leading `\b` (they start with non-word chars). The command
   patterns use `\bralph-(start|spec|implement|status)\b` (word
   boundary, no literal slash) to catch both `/ralph-start` and bare
   `ralph-start` in prose — `ralph-failed` and `ralph-output` don't
   match because neither `failed` nor `output` appears in the
   alternation, so heritage verb-noun forms are safe. The alternation
   is intentionally closed (rather than `\bralph-[a-z]+\b`) so heritage
   verb-noun additions stay safe; new identity-bearing commands get
   added to this list explicitly. `\bRALPH_[A-Z_]+` is anchored with
   `\b` to avoid matching the renamed `SENSIBLE_RALPH_*` substring (the
   `_` between `SENSIBLE` and `RALPH` is a word character, so the
   boundary doesn't fire — without `\b` every successfully-renamed env
   var would still trip the grep). `\bralph_[a-z]` catches
   underscore-form identifiers like the `ralph_spec` token in graphviz
   diagrams. Heritage strings (`snarktank/ralph`, `vanilla ralph`,
   `ralph technique`) don't match any alternation.

   Each remaining line must be a heritage reference: vanilla ralph
   narrative, the technique citation, fork links, or a spec filename
   carve-out (`docs/specs/ralph-status-command.md` etc. — filenames
   stay; in-content identifiers don't).
2. **Heritage references intact.** README's "vanilla ralph"
   comparisons, the snarktank/frankbria links, and all three
   `docs/specs/*-design.md` files are not touched by the rename sweep.
3. **Plugin manifest userConfig defaults unchanged.**
   `failed_label: "ralph-failed"`,
   `stdout_log_filename: "ralph-output.log"`.
4. **All bats tests pass.**
   ```bash
   bats skills/sr-start/scripts/test/*.bats \
        skills/sr-status/scripts/test/*.bats
   ```
5. **Fresh `/sr-start` invocation creates `.sensible-ralph/progress.json`**
   (not `.ralph/progress.json`), verified through the bats suite above.
6. **`.gitignore` lists `/.sensible-ralph/`** and does NOT list
   `/.ralph/`. The `/.worktrees/` and `ralph-output.log` lines unchanged.
7. **Plugin namespace resolves.** `sensible-ralph:sr-start`,
   `sensible-ralph:sr-spec`, `sensible-ralph:sr-implement`,
   `sensible-ralph:sr-status` (and the unprefixed `/sr-start`,
   `/sr-spec`, `/sr-implement`, `/sr-status`) load via Claude Code's
   skill discovery from `.claude-plugin/`.
8. **Env-var guard checks pass at runtime.** Every shell script that
   gates on `[[ "${SENSIBLE_RALPH_SCOPE_LOADED:-}" != "$EXPECTED_SCOPE_LOADED" ]]`
   loads scope correctly when the new env var is set.
9. **Runtime base-SHA marker still present.** The extensionless
   `.ralph-base-sha` file at the worktree root must NOT be renamed or
   deleted during the task. Verify before handing off:
   ```bash
   test -f .ralph-base-sha \
     && echo "OK — runtime marker present" \
     || echo "ERROR — marker missing; cached /prepare-for-review will use wrong base"
   ```
   Source code *references* to `.ralph-base-sha` in `orchestrator.sh`
   and SKILL.md files rename correctly (to `.sensible-ralph-base-sha`);
   only the runtime file at the worktree root is exempt.

## Verification (run in this order)

1. `bats skills/sr-start/scripts/test/*.bats
   skills/sr-status/scripts/test/*.bats` — load-bearing integration
   check.
2. The acceptance grep from criterion 1 — only heritage carve-outs may
   remain.
3. From a scratch consumer repo with the new gitignore template, run
   `/sr-start` against a test fixture and verify
   `.sensible-ralph/progress.json` materializes at the repo root.

If 1–3 all pass, the rename is verified. No other behavior changes, so
no broader regression suite is needed.

## Prerequisites

`blocked-by ENG-255` (Relocate orchestrator artifacts under `.ralph/`).
ENG-255 introduces the `.ralph/` directory and updates ~9 file
surfaces; this rename inherits that work and renames the directory and
the surrounding identifier set. Concurrent execution would conflict on
the shared `.gitignore` line, the README gitignore example block, and
`orchestrator.sh` paths.

ENG-255 is in the `Sensible Ralph` Linear project, which is the only
project in this repo's `.ralph.json` scope, so `/sr-start`'s
out-of-scope-blocker preflight will accept the relation.

## Commit shape

One atomic commit. Suggested message:

```
fix: rename ralph plugin-identity surfaces to sensible-ralph

Align plugin-identity surfaces with the actual plugin name. Renamed:
.ralph.json → .sensible-ralph.json, .ralph/ → .sensible-ralph/,
.ralph-base-sha → .sensible-ralph-base-sha, RALPH_* env vars →
SENSIBLE_RALPH_*, slash commands /ralph-{start,spec,implement,status}
→ /sr-{start,spec,implement,status} and their skill directories.

Heritage references unchanged: "vanilla ralph" narrative, snarktank
and frankbria fork links, archived docs, design records, the
ralph-failed label default, and the ralph-output.log filename default
(verb-noun reading: "the ralph dispatcher's output").

Closes ENG-276.
```

Branch: `eng-276-rename-ralph-to-sensible-ralph-across-plugin-surfaces`
(Linear default).
