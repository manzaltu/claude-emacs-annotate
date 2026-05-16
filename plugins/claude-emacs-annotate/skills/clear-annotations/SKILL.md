---
name: clear-annotations
description: Use when user types /clear-annotations to remove every claude-emacs-annotate thread opened by the annotate skills (root author "claude-code") in the current git project. Threads opened by other authors are left untouched, even when they contain "claude-code" replies. With --tag, removes only the named annotation set; with --all, removes every annotation in the project regardless of author.
argument-hint: "[--all | --tag <tag>]"
allowed-tools: [Bash]
---

# /clear-annotations — bulk-remove skill-authored annotations

Run the bundled `clear-ai.sh` against the current git project.

## When to use

Only when the user invokes `/clear-annotations` (with or without the argument). Do not volunteer.

## The arguments

`$ARGUMENTS` is empty, `--tag <tag>`, or `--all`:

| Input | Meaning |
| --- | --- |
| *(empty)* | Remove only threads whose root author is `claude-code` — every annotation set, any tag or none. |
| `--tag <tag>` | Remove only `claude-code` threads carrying that tag: one annotation set (`changes` for the `/annotate-changes` set, a task tag for a `/annotate` set). Other sets survive. |
| `--all` | Remove **every** annotation in the project, including threads the user opened themselves. |

`--all` irreversibly deletes the user's own annotations. Pass it only when the user's invocation included it — never escalate a plain `/clear-annotations` to `--all` on your own, and never suggest it as a workaround for anything.

## Where to invoke from

**Always `cd` to the project root before running `clear-ai.sh`.** The script scopes itself via `git rev-parse --show-toplevel` of the **current working directory**, not by any project root passed as an argument. If your shell is inside a nested git repo (a submodule, a worktree, or any embedded repo), the clear silently operates on that nested repo only and leaves annotations in the outer project untouched. Do not trust a prior shell cwd — run `cd <project-root>` explicitly before invoking.

## Procedure

1. `cd` to the project root, then run `clear-ai.sh $ARGUMENTS` from the plugin's shared `scripts/` directory — its absolute path is `${CLAUDE_PLUGIN_ROOT}/scripts`; use that path verbatim, never guess it from the install layout or normalize a relative path in your head (if it turns out not to exist, resolve the directory with `realpath "${CLAUDE_SKILL_DIR}/../../scripts"`). The script uses `git rev-parse --show-toplevel` of the CWD for scope and prints JSON.
2. Surface the result to the user: `removed` (how many threads were deleted), plus the `mode`/`tag` so it's unambiguous which set was cleared.
3. If the script aborts (Emacs server unreachable, package not loaded), relay the error and stop — do not retry or fall back.

By default the script only touches threads whose root-comment author equals the skill's `ANNOTATE_AUTHOR` (currently `"claude-code"`). Other authors' threads and annotations in other projects survive. In particular, a thread the user opened themselves is left fully intact even when it contains `claude-code` replies posted by `/reply-annotations` — the discriminator is the root comment's author, never a reply's. With `--tag`, the same author filter applies plus the thread must carry the tag, so exactly one annotation set is removed. With `--all`, the author filter is dropped and every annotation in scope is removed — user-opened threads included; annotations in other projects still survive. Removal happens straight in the project's store; no buffers are opened and no source files are touched.
