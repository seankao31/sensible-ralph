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

Run from anywhere inside the repo. The renderer resolves paths via `git rev-parse --git-common-dir`, so it works from the main checkout, a linked worktree, or any subdirectory.

Output is a sectioned table — Done / Running / Queued — for the latest ralph run. See `docs/usage.md` "Checking progress mid-run" for the operator-facing playbook, and the spec at `docs/specs/sr-status-command.md` if it has been written.

## Step 1: Render

Invoke the renderer and print its stdout verbatim:

```bash
bash "$CLAUDE_PLUGIN_ROOT/skills/sr-status/scripts/render_status.sh"
```

The renderer exits 0 even when no runs have been recorded (it prints a hint), and exits 1 only when invoked outside a git repo. No other failure paths.
