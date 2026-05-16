---
name: annotate-clear
description: Use when user types /annotate-clear to remove every skill-authored simply-annotate annotation (author "claude-code") in the current git project. Other authors' annotations are left untouched.
allowed-tools: [Bash]
---

# /annotate-clear — bulk-remove skill-authored annotations

Run the bundled `clear-ai.sh` against the current git project.

## When to use

Only when the user invokes `/annotate-clear`. Do not volunteer.

## Where to invoke from

**Always `cd` to the project root before running `clear-ai.sh`.** The script scopes itself via `git rev-parse --show-toplevel` of the **current working directory**, not by any project root passed as an argument. If your shell is inside a nested git repo (a submodule, a worktree, or any embedded repo), the clear silently operates on that nested repo only and leaves annotations in the outer project untouched. Do not trust a prior shell cwd — run `cd <project-root>` explicitly before invoking.

## Procedure

1. `cd` to the project root, then run `scripts/clear-ai.sh` (in this skill's folder). The script uses `git rev-parse --show-toplevel` of the CWD for scope.
2. Surface the returned counts to the user: files considered, annotations removed, files visited.
3. If `emacsclient` is unreachable, relay the error and stop — do not retry or fall back.

The script only touches annotations whose root-comment author equals the skill's `ANNOTATE_AUTHOR` (currently `"claude-code"`). Other authors' annotations and annotations in other projects survive.
