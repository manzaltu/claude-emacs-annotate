---
name: annotate-changes
description: Use when user types /annotate-changes to leave inline AI-authored annotations on a working-tree diff via the claude-emacs-annotate Emacs package. Annotations are written as annotation threads with author "claude-code" so they can be cleanly distinguished from user-authored annotations.
argument-hint: "[HEAD|sha|branch]  (default: branch)"
allowed-tools: [Bash, Read]
---

# /annotate-changes — explain a diff via inline annotations

This skill walks a git diff and leaves one annotation per change so the user can read your reasoning inline in Emacs. It does not modify source files. Annotations live in the project's claude-emacs-annotate store (one file per project under `claude-emacs-annotate-directory`) and render as the package's overlays in any buffer that visits the file. Each annotation this skill creates is a thread whose root comment carries `author = "claude-code"`; that author field is the discriminator every script uses to find skill-authored entries (defined as `ANNOTATE_AUTHOR` in `lib.sh`). Every thread it creates also carries the tag `changes`, which separates this skill's annotation set from the instruction-driven sets the generic `/annotate` skill writes under the same author.

The skill runs in **update mode**: it does not bulk-clear existing skill-authored annotations on entry. Instead it reads them, compares them against the current diff, and reconciles. The reconcile logic preserves history rather than discarding it: when a code change disappears or moves, the annotation describing it is **closed** (`status: closed`) so the original prose remains in the store as an audit trail. Closed annotations are inert — they still appear in `list-ai.sh` output but the reconciler ignores them when matching against new diff records, so they are never re-opened or duplicated. Use `clear-ai.sh --tag changes` only as an explicit reset when an update goes sideways; the bare form also removes the generic `/annotate` skill's sets.

**Announce when you start**: tell the user you're running `/annotate-changes <baseline>` and what that resolves to.

## When to use

Only when the user invokes `/annotate-changes` (with or without an argument). Never volunteer to annotate spontaneously. Instruction-driven annotation that is not about explaining a diff (code review, walkthroughs, audits) belongs to the generic `/annotate` skill.

## The script contract

**Read `${CLAUDE_PLUGIN_ROOT}/scripts/README.md` before invoking any script** (if that path does not exist, resolve the directory with `realpath "${CLAUDE_SKILL_DIR}/../../scripts"`). It is the single copy of the shared contract: where the scripts live, the always-`cd`-to-the-project-root rule, the script table, the `list-ai.sh`/`batch.sh`/`diff.sh` output formats, the failure modes, and the notes for the user. References like `scripts/diff.sh` below mean that directory. This skill's deltas on top of the contract:

- The tag is always `changes` here: pass it to `annotate.sh`/`batch.sh` for every create, and to `clear-ai.sh --tag changes` when the user asks for a reset of this set only.
- Additional failure mode — **working tree has no diff against the baseline**: `diff.sh` produces no output. Every still-open annotation in your partition now falls into the "no overlapping diff record" branch and should be **closed** by the normal reconcile step (stale ones included) — do not skip the reconcile pass just because the diff is empty. Other tags' annotations stay untouched as always. Confirm to the user that the diff was empty and report how many annotations were closed.

## The baseline argument

`$ARGUMENTS` is one of:

| Input | Meaning |
| --- | --- |
| *(empty)* | Same as `branch`. |
| `branch` | Diff merge-base(primary, HEAD) → working tree. Primary is `main`, falling back to `master`, then HEAD's upstream. Covers branch commits **and** dirty changes. |
| `HEAD` | Diff HEAD → working tree. Annotates only uncommitted changes. |
| any other ref/SHA | Diff that commit → working tree. |

If `lib.sh` cannot resolve `branch` (no `main`/`master`/upstream), the script prints a clear error and you should relay it to the user instead of guessing a fallback.

## Procedure

1. **Read existing annotations**: run `scripts/list-ai.sh` and capture the array. **Filter to `status == "open"`** for reconciliation; closed annotations are historical audit trail and must not participate — but record the closed count (`jq '[.[] | select(.status == "closed")] | length'`) for the verify step. Partition the open annotations by tag: threads whose `tags` contains `changes` are yours. Threads carrying any other tag belong to the generic `/annotate` skill's instruction-driven sets and are not yours to touch — never keep, edit, or close them, however they overlap the diff — but record how many you set aside for the verify step. Each participating annotation is keyed by `(abs_file, anchor.start_line, anchor.end_line)` and addressed by its `thread_id`; a whole-file annotation (`anchor.kind == "file"`, null lines) participates as if it spanned every line of its file. Do *not* clear them.
2. **Compute the diff**: run `scripts/diff.sh "$ARGUMENTS"`. Capture every record.
3. **Understand the changes before annotating**: thoroughly read the full diff and read any additional files needed to actually understand each change — call sites, related types, sibling files, headers, tests, anything that clarifies the *why*. Do not skim. The annotation prose has to explain intent and consequence, and you cannot do that from a hunk in isolation. Spend the reading time up front; it is cheaper than writing wrong annotations and rewriting them.
4. **Reconcile each diff record against open annotations**. For every diff record, find the participating open annotation(s) — your partition from step 1 — on the same file whose line range overlaps. Annotations participate at their reported lines regardless of `anchor.state`: `fresh` lines are current, and a `stale` annotation's reported lines are its last known location, so a stale annotation overlapping a modified hunk naturally lands in the Close + Create row below. Apply this rule table — it is exhaustive; do not invent other categories:

   | Situation | Action |
   | --- | --- |
   | Diff record has no overlapping open annotation. | **Create**: queue a spec object for `batch.sh changes`. |
   | Open annotation matches the diff range exactly, code at that range is unchanged from when the annotation was written, and its prose still describes the code accurately (re-read the file at that location to verify). | **Keep**: do nothing. |
   | Open annotation matches the diff range exactly, code at that range is unchanged, but the prose is now wrong (you understand it better the second time, or it was inaccurate to begin with). | **Edit in place**: pipe the new prose into `scripts/edit.sh <thread_id> --expect-file <abs_file>`. The annotation's status stays `open`; only the prose changes. There is no audit trail for prose-only refinements — that is intentional. |
   | Open annotation overlaps the diff range but the code at that location was modified (range grew/shrank, or content within the same range changed). | **Close + Create**: `scripts/close.sh <thread_id> --expect-file <abs_file>` to preserve the original prose as history, then queue a fresh spec at the new range with new prose describing the current code. Do **not** reuse the old prose verbatim — the code is different now. |
   | Open annotation has no overlapping diff record (the change went away — reverted, refactored elsewhere, or the file is no longer in the diff). | **Close**: `scripts/close.sh <thread_id> --expect-file <abs_file>`. The annotation stays in the store with `status: closed` so the original prose is preserved as audit trail. |
   | Open annotation has `anchor.state == "stale"` and no earlier row applied. | **Close**: the code it described changed or is gone. If the diff still contains that change at a new location, the "no overlapping open annotation" row will create a fresh one there. |
   | Annotation is already `closed`. | **Ignore entirely**. Do not match it against diff records, do not consider it for keep/edit/close. It is inert history. |

   If a single diff record overlaps **multiple** open annotations (because a previous run segmented one hunk into several sub-annotations), pick the one whose range best matches the current hunk and apply Keep/Edit/Close+Create to it; **close** the rest. Don't try to preserve a sub-segmentation the new diff no longer supports — that path leads to drift between annotations and code.

   For `new` records, decide the segmentation up front:
   - If the new file is a *single artifact* (one tracking doc, one config blob, one trivial helper script), emit one whole-file annotation (`"kind": "file"` in the spec, or `annotate.sh --whole-file`).
   - Otherwise read the file and segment it by logical sections (top-level definitions, classes, comment blocks, configuration sections — whatever fits the language), and create one annotation per section.

   **Prefer `batch.sh changes`** for the create queue when you have more than a handful of new specs — build the JSON array in memory and pipe it once; this is far faster than per-record `annotate.sh` calls and gathers all errors in one report. `edit.sh` and `close.sh` are per-call; for typical update runs the edit/close count is small and the per-call cost is fine.
5. **Verify**: run `scripts/count.sh`. `jq -r '.open_by_tag.changes // 0'` must equal `(kept + edited + created)`, every other `open_by_tag` bucket must match its set-aside count from step 1 (an unexpected bucket is itself a discrepancy), and `jq -r '.by_status.closed'` must equal `(closed-at-step-1 + closed-this-run)`. If they don't match, surface the discrepancy to the user before claiming success — the store is the source of truth, not your tally of how many times you called each script.
6. **Confirm**: tell the user the breakdown — `created`, `kept`, `edited`, `closed` — plus the running closed total in the store, and which files were touched. Offer to revise specific annotations on request.

## Annotation prose rules

- Write the prose as plain text — no `[AI]` prefix, no marker. Authorship is recorded in the thread's `author` field, not in the text.
- One short paragraph (≤ 4 sentences). Present tense. Describe **what the change does** and **why it matters**, not the diff line-by-line — the user can already see the diff.
- Never refer to yourself, "Claude", "the assistant", or the model. The author field carries provenance; the prose itself should read as a comment about the code, not about the writer.
- Do not paste raw diff lines or file paths into the prose; the annotation already lives at the relevant location.
- If a change is purely mechanical (rename, formatting), say so briefly rather than padding.

## Editing your own annotations

After writing annotations you may realize a description was wrong-headed. In that case:

- Use `edit.sh` to overwrite the prose in place — the annotation's status, id, author, and creation timestamp are preserved; the new text is stamped `edited`, and the anchor is re-pinned against the current code (clearing a stale flag whenever the spot is still locatable). The thread id (from `list-ai.sh`) identifies which annotation to update.
- Use `close.sh` to retire an annotation while keeping its prose in the store as audit trail; this is what the reconcile step uses for code-removed and code-changed cases.
- `delete.sh` is reserved for accidents (bogus annotation written by mistake at a wrong location) — the normal flow does not use it. Hard-deletion drops the prose with no history.
- Always pass `--expect-file <abs_file>` to `edit.sh`/`close.sh`/`delete.sh` — ids come from your own listing, and the cross-check turns a stale id into a clean abort instead of a wrong-thread edit.

Never invoke the scripts to touch annotations you did not create — the listings are scoped to entries whose root author equals `ANNOTATE_AUTHOR` by design, but you should still be deliberate about which annotations you keep, edit, or close.

## Failure modes

The shared failure modes — unreachable server, package not loaded, not in a git repo, stale thread ids, `--expect-file` mismatches, out-of-scope files, unencodable filenames — live in the script contract (`scripts/README.md`), along with the notes worth relaying to the user. This skill adds one of its own: **working tree has no diff against the baseline** (see "The script contract" above).
