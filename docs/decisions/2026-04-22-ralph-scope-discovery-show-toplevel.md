# Ralph scope discovery uses --show-toplevel, not --git-common-dir

## Context

`lib/config.sh` discovers the `.ralph.json` scope file by resolving the current
working tree's root. `lib/worktree.sh` also exposes `_resolve_repo_root`, which
uses `git rev-parse --git-common-dir` to find the main checkout (intentionally
shared across all linked worktrees). These two functions have different
`git rev-parse` flags and return different directories when invoked from a
linked worktree.

## Decision

`config.sh` uses `git rev-parse --show-toplevel` for scope discovery, NOT the
shared `_resolve_repo_root` function from `worktree.sh`.

## Reasoning

`--git-common-dir` always resolves to the main checkout's `.git` parent —
that's what worktree.sh wants for progress.json and `.worktrees/<branch>` paths
(shared state intentionally read/written from one location regardless of which
worktree the user is in).

`.ralph.json` is different: it's a committed file whose content should follow
the currently checked-out branch. If you're in a linked worktree on a branch
with a different scope (or no `.ralph.json` at all), you must see that branch's
version, not the main checkout's. `--show-toplevel` returns the current worktree's
own root — the right semantic for committed, branch-local config.

Using `--git-common-dir` here would produce a silent wrong-scope read: an
operator standing in a branch worktree with a modified `.ralph.json` would
query Linear against the main checkout's scope, with no error signal.

## Consequences

**Do not "align" config.sh to use `_resolve_repo_root`** even though it looks
inconsistent. The inconsistency is the point: two different git paths, two
different data-locality requirements.

If you add new config that belongs to the main checkout (like progress.json),
use `_resolve_repo_root` (`--git-common-dir`). If you add new config that
belongs to the branch checkout (like `.ralph.json`), use `--show-toplevel`.
