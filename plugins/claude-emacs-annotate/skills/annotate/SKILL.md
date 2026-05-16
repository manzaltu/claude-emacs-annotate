---
name: annotate
description: Use when user types /annotate to leave inline AI-authored annotations on a working-tree diff via the simply-annotate Emacs package. Annotations are written as simply-annotate threads with author "claude-code" so they can be cleanly distinguished from user-authored annotations.
argument-hint: "[HEAD|sha|branch]  (default: branch)"
allowed-tools: [Bash, Read]
---

# /annotate — explain a diff via inline annotations

This skill walks a git diff and leaves one annotation per change so the user can read your reasoning inline in Emacs. It does not modify source files. Annotations live in the simply-annotate database (`~/.emacs.d/.cache/simply-annotations.el`) and render as overlays in any buffer that visits the file. Each annotation this skill creates is a simply-annotate thread whose root comment carries `author = "claude-code"`; that author field is the discriminator every script uses to find skill-authored entries (defined as `ANNOTATE_AUTHOR` in `lib.sh`).

The skill runs in **update mode**: it does not bulk-clear existing skill-authored annotations on entry. Instead it reads them, compares them against the current diff, and reconciles. The reconcile logic preserves history rather than discarding it: when a code change disappears or moves, the annotation describing it is **closed** (`status: closed`) so the original prose remains in the database as an audit trail. Closed annotations are inert — they still appear in `list-ai.sh` output but the reconciler ignores them when matching against new diff records, so they are never re-opened or duplicated. Use `clear-ai.sh` only as an explicit reset when an update goes sideways.

**Announce when you start**: tell the user you're running `/annotate <baseline>` and what that resolves to.

## When to use

Only when the user invokes `/annotate` (with or without an argument). Never volunteer to annotate spontaneously.

## Where to invoke from

**Always `cd` to the project root before invoking any script in this skill.** The bundled scripts scope themselves via `git rev-parse --show-toplevel` of the **current working directory**, not by any project root passed as an argument. If your shell is inside a nested git repo (a submodule, a worktree, or any embedded repo), the scripts silently operate on that nested repo only, and annotations elsewhere are left untouched. Do not trust a prior shell cwd — run `cd <project-root>` explicitly before each invocation.

## The baseline argument

`$ARGUMENTS` is one of:

| Input | Meaning |
| --- | --- |
| *(empty)* | Same as `branch`. |
| `branch` | Diff merge-base(primary, HEAD) → working tree. Primary is `main`, falling back to `master`, then HEAD's upstream. Covers branch commits **and** dirty changes. |
| `HEAD` | Diff HEAD → working tree. Annotates only uncommitted changes. |
| any other ref/SHA | Diff that commit → working tree. |

If `lib.sh` cannot resolve `branch` (no `main`/`master`/upstream), the script prints a clear error and you should relay it to the user instead of guessing a fallback.

## Bundled scripts

All scripts live in `scripts/` next to this file. Invoke them via `Bash` from the project root (their CWD must be inside the target git repo — they call `git rev-parse --show-toplevel` to scope themselves).

| Script | Purpose | Stdin |
| --- | --- | --- |
| `list-ai.sh` | List every existing skill-authored annotation in scope as TSV (open and closed). | — |
| `diff.sh [BASELINE]` | Print one TAB-separated record per region to annotate. | — |
| `annotate.sh <abs-file> <start> <end>` | Create one skill-authored annotation (status defaults to open). | annotation text |
| `batch.sh` | Create many annotations in one Emacs round-trip. | one TSV record per line |
| `edit.sh <abs-file> <start> <end>` | Replace the prose of an existing skill-authored annotation in place (does not change its status, identity, or comment metadata). | new annotation text |
| `close.sh <abs-file> <start> <end>` | Set an existing skill-authored annotation's status to `closed`, preserving its prose. Idempotent. | — |
| `delete.sh <abs-file> <start> <end>` | Hard-delete a single skill-authored annotation. Reserved for accidents — the normal flow uses `close.sh` instead. | — |
| `count.sh` | Report `:ai-open` / `:ai-closed` counts plus the total. | — |
| `clear-ai.sh` | Remove every skill-authored annotation in the current project. Reset tool — not part of the normal procedure. | — |

`diff.sh` output is `kind<TAB>abs-path<TAB>start-line<TAB>end-line` per line, where `kind` is `modified` (one line per hunk) or `new` (one line per added/untracked file, with start=1 and end=line-count).

`list-ai.sh` output is a 5-column TSV: `<abs-file><TAB><start-line><TAB><end-line><TAB><status><TAB><text>` per line. `<status>` is `open` / `in-progress` / `resolved` / `closed`. Embedded newlines in text are encoded as the two-character sequence `\n` (backslash + n). Line numbers are converted from stored buffer positions, so they key directly against `diff.sh` records. **The status column is NOT consumed by `batch.sh`** — drop it when reusing rows for create.

`batch.sh` reads 4-column `<abs-file><TAB><start><TAB><end><TAB><text>` per line. Text must not contain literal TABs; embedded newlines are encoded as the two-character sequence `\n` (backslash + n) and decoded by the script. New annotations are always created as threads with `author = "claude-code"` and `status = "open"`.

## Procedure

1. **Read existing annotations**: run `scripts/list-ai.sh` and capture every record. The output is 5-column TSV with a status field. **Filter to status=open** for reconciliation; closed annotations are historical audit trail and must not participate. Each open annotation is keyed by `(abs-file, start-line, end-line)`. Do *not* clear them.
2. **Compute the diff**: run `scripts/diff.sh "$ARGUMENTS"`. Capture every record.
3. **Understand the changes before annotating**: thoroughly read the full diff and read any additional files needed to actually understand each change — call sites, related types, sibling files, headers, tests, anything that clarifies the *why*. Do not skim. The annotation prose has to explain intent and consequence, and you cannot do that from a hunk in isolation. Spend the reading time up front; it is cheaper than writing wrong annotations and rewriting them.
4. **Reconcile each diff record against open annotations**. For every diff record, find the open annotation(s) on the same file whose line range overlaps. Apply this rule table — it is exhaustive; do not invent other categories:

   | Situation | Action |
   | --- | --- |
   | Diff record has no overlapping open annotation. | **Create**: queue a new TSV row for `batch.sh`. |
   | Open annotation matches the diff range exactly, code at that range is unchanged from when the annotation was written, and its prose still describes the code accurately (re-read the file at that location to verify). | **Keep**: do nothing. |
   | Open annotation matches the diff range exactly, code at that range is unchanged, but the prose is now wrong (you understand it better the second time, or it was inaccurate to begin with). | **Edit in place**: pipe the new prose into `scripts/edit.sh <file> <start> <end>`. The annotation's status stays `open`; only the prose changes. There is no audit trail for prose-only refinements — that is intentional. |
   | Open annotation overlaps the diff range but the code at that location was modified (range grew/shrank, or content within the same range changed). | **Close + Create**: `scripts/close.sh <file> <old-start> <old-end>` to preserve the original prose as history, then queue a fresh TSV row at the new range with new prose describing the current code. Do **not** reuse the old prose verbatim — the code is different now. |
   | Open annotation has no overlapping diff record (the change went away — reverted, refactored elsewhere, or the file is no longer in the diff). | **Close**: run `scripts/close.sh <file> <start> <end>`. The annotation stays in the database with `status: closed` so the original prose is preserved as audit trail. |
   | Annotation is already `closed`. | **Ignore entirely**. Do not match it against diff records, do not consider it for keep/edit/close. It is inert history. |

   If a single diff record overlaps **multiple** open annotations (because a previous run segmented one hunk into several sub-annotations), pick the one whose range best matches the current hunk and apply Keep/Edit/Close+Create to it; **close** the rest. Don't try to preserve a sub-segmentation the new diff no longer supports — that path leads to drift between annotations and code.

   For `new` records, decide the segmentation up front:
   - If the new file is a *single artifact* (one tracking doc, one config blob, one trivial helper script), emit one whole-file annotation covering lines 1..N.
   - Otherwise read the file and segment it by logical sections (top-level definitions, classes, comment blocks, configuration sections — whatever fits the language), and create one annotation per section.

   **Prefer `batch.sh`** for the create queue when you have more than a handful of new rows — build the TSV in memory and pipe it once; this is far faster than per-record `annotate.sh` calls and gathers all errors in one report. `edit.sh` and `close.sh` are per-call; for typical update runs the edit/close count is small and the per-call cost is fine.
5. **Verify**: run `scripts/count.sh` and compare its `:ai-open` count against `(kept + edited + created)` from your reconciliation, and `:ai-closed` against `(closed-existing + closed-this-run)`. If they don't match, surface the discrepancy to the user before claiming success — the database is the source of truth, not your tally of how many times you called each script.
6. **Confirm**: tell the user the breakdown — `created`, `kept`, `edited`, `closed` — plus the running `:ai-closed` total in the database, and which files were touched. Offer to revise specific annotations on request.

## Annotation prose rules

- Write the prose as plain text — no `[AI]` prefix, no marker. Authorship is recorded in the thread's `author` field, not in the text.
- One short paragraph (≤ 4 sentences). Present tense. Describe **what the change does** and **why it matters**, not the diff line-by-line — the user can already see the diff.
- Never refer to yourself, "Claude", "the assistant", or the model. The author field carries provenance; the prose itself should read as a comment about the code, not about the writer.
- Do not paste raw diff lines or file paths into the prose; the annotation already lives at the relevant location.
- If a change is purely mechanical (rename, formatting), say so briefly rather than padding.

## Editing your own annotations

After writing annotations you may realize a description was wrong-headed. In that case:

- Use `edit.sh` to overwrite the prose in place — the annotation's status, id, comment timestamps, and author are preserved; only the root comment's text changes. The line range identifies which annotation to update; the script refuses to edit annotations by other authors.
- Use `close.sh` to retire an annotation while keeping its prose in the database as audit trail; this is what the reconcile step uses for code-removed and code-changed cases.
- `delete.sh` is reserved for accidents (bogus annotation written by mistake at a wrong location) — the normal flow does not use it. Hard-deletion drops the prose with no history.
- If `edit.sh`, `close.sh`, or `delete.sh` reports "multiple skill-authored annotations match", you've overlapped two hunks at the same range; pick a tighter range or close the duplicates one at a time after inspecting them.

Never invoke the scripts to touch annotations you did not create — they're scoped to entries whose author equals `ANNOTATE_AUTHOR` by design, but you should still be deliberate about which annotations you keep, edit, or close.

## Failure modes

- **Emacs server unreachable**: `emacsclient` errors out with a clear message. Tell the user to start Emacs (or run `M-x server-start`) and abort. Do not attempt any fallback.
- **Not in a git repo**: `lib.sh` aborts with `not inside a git repository`. Relay this and stop.
- **Filename with TAB or NEWLINE**: `diff.sh` refuses to emit it. Skip those files and tell the user.
- **Working tree has no diff against the baseline**: `diff.sh` produces no output. Every still-open in-scope skill-authored annotation now falls into the "no overlapping diff record" branch and should be **closed** by the normal reconcile step — do not skip the reconcile pass just because the diff is empty. Confirm to the user that the diff was empty and report how many annotations were closed.
- **`list-ai.sh` reports a stale annotation on stderr**: the stored position no longer maps to a valid line range in the file (the file shrank or was rewritten outside the current diff). The script omits it from stdout, so it does not participate in reconciliation. Mention the warning in your final summary; the user may want to investigate, but it is not a hard error.

## Notes for the user

- The simply-annotate display style is configurable; the user may need `M-x simply-annotate-cycle-display-style` to make annotations visible inline.
- Annotations persist across Emacs sessions via `simply-annotations.el`.
- Buffers opened by the scripts are closed afterward unless they were already visited; nothing is auto-saved.
