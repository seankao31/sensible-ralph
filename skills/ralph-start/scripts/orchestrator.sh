#!/usr/bin/env bash
set -euo pipefail

# Dispatch loop: consume an ordered queue of issue IDs, pre-create the
# worktree at the DAG-chosen base, transition Linear state, invoke
# `claude -p` with the rendered prompt, classify outcomes, and append to
# progress.json. Implementation lands in ENG-184 Task 8.

exit 0
