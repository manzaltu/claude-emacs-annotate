---
name: annotate
description: Use when user types /annotate <instructions> to leave inline AI-authored annotations on code driven by free-form instructions — code review, security audits, explanation walkthroughs, assumption flagging, or any other scenario where prose pinned to specific lines is the deliverable. Not tied to diffs; the instructions define both the scope and what each annotation says. Annotations are written as claude-emacs-annotate threads with author "claude-code" and a task-derived tag, so annotation sets from different tasks coexist and update independently.
argument-hint: "[--tag <tag>] <instructions>  (e.g. 'review src/parser.c for memory-safety issues')"
allowed-tools: [Bash, Read, Grep, Glob]
---

# /annotate — annotate code from custom instructions

This skill turns free-form instructions into inline annotations: the user says what to look at and what kind of prose to leave, you read the code and pin one annotation thread to the exact lines each remark concerns. Nothing here assumes a diff, a branch, or even a change — the instructions alone define the **scope** (which files and regions) and the **task** (what each annotation contains). It is the generic member of the annotate family; `/annotate-changes` is the specialized flow for explaining a git diff and reconciles against it mechanically.

The skill does not modify source files. Annotations live in the project's claude-emacs-annotate store (one file per project under `claude-emacs-annotate-directory`) and render as the package's overlays in any buffer that visits the file. Each annotation is a thread whose root comment carries `author = "claude-code"` (defined as `ANNOTATE_AUTHOR` in `lib.sh`) — the same author every annotate skill uses, so the user can answer these threads via `/reply-annotations` and wipe them via `/clear-annotations`. What separates one annotation set from another is the thread's **tag**: every thread this skill creates carries exactly one task-derived tag, and every reconcile decision is scoped to it, so sets from different tasks — and the `changes` set the diff skill writes — coexist without ever touching each other.

Example invocations, to calibrate how broad "instructions" is:

- `/annotate review scripts/ for quoting and word-splitting bugs` — a code review; each annotation is one finding: the issue, why it matters, the fix if apparent.
- `/annotate explain the tricky parts of src/scheduler.rs to someone new to the codebase` — a walkthrough; each annotation explains one non-obvious section.
- `/annotate mark every place in the API layer that assumes a single tenant` — an audit; each annotation flags one occurrence of the property.
- `/annotate review my uncommitted changes for error handling` — a review whose scope happens to be a diff; `diff.sh` computes the regions, but the prose is review findings, not change explanations.

**Announce when you start**: tell the user you're running `/annotate` and restate the scope, the task, and the task tag you derived from the instructions, so a misreading surfaces before the work.

## When to use

Only when the user invokes `/annotate` with instructions. Never volunteer to annotate spontaneously. If the instructions amount to "explain my diff" with no further task, point the user at `/annotate-changes` instead — its mechanical diff reconciliation is built for exactly that.

## The script contract

**Read `${CLAUDE_PLUGIN_ROOT}/scripts/README.md` before invoking any script** (if that path does not exist, resolve the directory with `realpath "${CLAUDE_SKILL_DIR}/../../scripts"`). It is the single copy of the shared contract: where the scripts live, the always-`cd`-to-the-project-root rule, the script table, the `list-ai.sh`/`batch.sh`/`diff.sh` output formats, the failure modes, and the notes for the user. References like `scripts/batch.sh` below mean that directory. This skill's deltas on top of the contract:

- `diff.sh` is an optional scoping helper here — use it only when the instructions scope by "my changes"; explaining the diff itself is `/annotate-changes`' job.
- Additional failure mode — **scope resolves to nothing**: the named files don't exist, the described layer can't be found, the property matches nowhere it could even be searched. Report what you looked for and where; do not invent a scope.

## The instructions argument

`$ARGUMENTS` is free-form prose, optionally preceded by `--tag <tag>` (see "The task tag" — the flag pins the tag instead of deriving it; strip it before reading the rest as instructions). Derive two things from the prose:

- **Scope** — which code to examine. It may be named explicitly ("in src/parser.c"), structurally ("the API layer"), by property ("every place that assumes a single tenant"), or as a set of changes ("my uncommitted changes" — run `scripts/diff.sh [BASELINE]` to compute the regions; using a diff to *scope* the work is fine, explaining the diff itself is `/annotate-changes`' job). Resolve structural or property-based scopes by actually searching and reading, not by guessing from file names.
- **Task** — what each annotation should say: review findings, explanations, flagged assumptions, migration notes, whatever the instructions call for. The task also sets the bar for what deserves an annotation at all — a review annotates problems, a walkthrough annotates the non-obvious, an audit annotates every match.

If `$ARGUMENTS` is empty, or you cannot derive a scope or a task from it, ask the user what they want annotated — do not guess, and do not fall back to annotating a diff.

## The task tag

Every annotation set is identified by a tag, and fixing it is the first concrete decision of a run:

- **Override**: when the invocation starts with `--tag <tag>`, use that tag verbatim — no derivation, no second-guessing. The only exception is `changes`: refuse it and tell the user it is reserved for `/annotate-changes`.
- **Form** (when deriving): short kebab-case, from the task — `review-quoting`, `explain-scheduler`, `single-tenant-audit`. Allowed characters: alphanumerics, `.`, `_`, `-` (enforced by the scripts).
- **Reserved**: `changes` belongs to `/annotate-changes`. Never use it here.
- **Stability** (when deriving): the tag is how a re-run finds its own previous output. Before minting a new tag, look at the `tags` arrays already present in the `list-ai.sh` output: if one plainly identifies an earlier run of these same instructions, reuse it — that set is what you will reconcile against. Otherwise mint a fresh one; a fresh tag means a fresh, coexisting set. When the user wants derivation out of the loop entirely, they pass `--tag`.
- **Announce the tag** along with the scope and task, and repeat it in the final summary — it is the handle the user needs for `/clear-annotations --tag <tag>` and `/reply-annotations --tag <tag>`.

## Procedure

1. **Derive scope and task** from `$ARGUMENTS` (see above). Ask instead of guessing when either is underivable.
2. **Read existing annotations and fix the tag**: run `scripts/list-ai.sh` and capture the array. Fix the task tag (see "The task tag"): use the `--tag` override when given, otherwise derive it — reusing an existing tag if the output shows one from an earlier run of these instructions — and announce it with the scope and task. **Filter to `status == "open"` and the task tag in `tags`** (e.g. `jq '[.[] | select(.status == "open" and (.tags | index("<tag>")))]'`): those threads are the in-task set you will reconcile, and their count is your baseline. Every other thread — the `changes` set, other tasks' tags — is out of scope: never keep, edit, or close it, however it overlaps the regions you are about to annotate. Coexisting annotation sets are a feature, not a conflict.
3. **Read the code in scope thoroughly**: resolve the scope to concrete files and regions, then read them plus whatever surrounding context the task demands — call sites, related types, tests, headers. Do not skim. Whatever the task, the prose has to hold up when the user reads it at that location days later, and you cannot write that from a fragment in isolation.
4. **Decide the annotation set**: one thread per remark — one finding, one explained section, one flagged occurrence. Anchor each to the tightest line range that contains its subject; annotate the occurrence, not the whole file. Whole-file annotations (`kind: "file"`) are for remarks genuinely about the file as a unit. When two distinct remarks land on the same lines, prefer merging them into one thread or splitting them onto distinct sub-ranges — ids keep even same-range threads addressable, but overlapping twins read poorly in the buffer.
5. **Reconcile against in-task annotations** — this makes re-running the same instructions an update, not a duplication. In-task threads with `anchor.state` of `fresh` participate at their reported lines; `stale` means the anchored content changed or is gone — re-read the reported location before deciding, and know that **editing re-pins**: `edit.sh` re-anchors the thread against the current code and clears the flag whenever its spot is still locatable. Apply this rule table:

   | Situation | Action |
   | --- | --- |
   | New remark with no overlapping in-task annotation. | **Create**: queue a spec object for `batch.sh <tag>`. |
   | In-task annotation whose range still fits its subject and whose prose still holds (re-read the code there to verify). | **Keep**: do nothing. |
   | In-task annotation whose range still fits but whose prose is wrong or outdated. | **Edit in place**: pipe the new prose into `scripts/edit.sh <thread_id> --expect-file <abs_file>`. |
   | In-task annotation whose subject moved or changed so the range no longer fits. | **Close + Create**: `scripts/close.sh <thread_id> --expect-file <abs_file>`, then queue a fresh spec at the new range. |
   | In-task annotation whose subject no longer warrants a remark (issue fixed, section rewritten, occurrence gone). | **Close**: `scripts/close.sh <thread_id> --expect-file <abs_file>`. The prose survives in the store as audit trail. |
   | In-task annotation with `anchor.state == "stale"`. | **Re-examine the reported lines.** If the current analysis still wants this remark there, **Edit** — the rewritten prose re-pins the thread and clears the flag. Otherwise **Close**; if the same remark applies somewhere else now, also queue a fresh spec there. |
   | Out-of-task annotation, any overlap. | **Ignore entirely.** |

   Thread ids come from the tag-filtered listing, so a cross-set hit is impossible; `--expect-file` additionally guards against a stale id landing on the wrong file.

   **Prefer `batch.sh <tag>`** for the create queue when you have more than a handful of specs — build the JSON array in memory and pipe it once. `edit.sh` and `close.sh` are per-call; typical edit/close counts make that fine.
6. **Verify**: run `scripts/count.sh` and check the task tag's bucket: `jq -r '.open_by_tag["<tag>"] // 0'` must equal `baseline − closed-this-run + created` (equivalently `kept + edited + created`). If it doesn't match, surface the discrepancy to the user before claiming success — the store is the source of truth, not your tally of script calls.
7. **Confirm**: tell the user the breakdown — `created`, `kept`, `edited`, `closed` — under which tag, plus which files carry annotations now. Offer to revise specific annotations on request.

Finding nothing is a valid outcome: a review can come back clean, an audit can match zero places. Create nothing, still close any in-task annotations whose subjects are gone, and say explicitly that the task produced no remarks — do not lower the bar to have something to show.

## Annotation prose rules

- Write the prose as plain text — no `[AI]` prefix, no marker. Authorship is recorded in the thread's `author` field, not in the text.
- Let the task shape the content: a review finding states the issue, its consequence, and the fix when one is apparent; an explanation states what the code does and why it is shaped that way; an audit flag states what property holds here and what to watch for. Default to one short paragraph (≤ 4 sentences) unless the instructions ask for more depth.
- Present tense. Each annotation must stand alone — the user reads it pinned to the code, not as part of a report, so no "as noted above" and no numbering schemes.
- Never refer to yourself, "Claude", "the assistant", or the model. The author field carries provenance; the prose reads as a comment about the code, not about the writer.
- Do not paste code snippets or file paths into the prose; the annotation already lives at the relevant location.

## Re-running and follow-ups

- Re-running `/annotate` with the same instructions resolves to the same tag and updates the existing set via the reconcile table — stale remarks close, surviving ones stay or get edited, new ones appear.
- Different instructions mint a different tag and produce a separate coexisting set; runs never disturb each other's output. The same holds between this skill and `/annotate-changes` (its set is tagged `changes`).
- The user answers or pushes back in the threads; `/reply-annotations` takes your turn there. Status transitions are the user's, as everywhere in the annotate family.
- `/clear-annotations --tag <tag>` removes one set; the bare form removes every claude-code thread in the project — all `/annotate` sets and `/annotate-changes` output alike. Point the user at the tagged form unless they want a full reset.

## Failure modes

The shared failure modes — unreachable server, package not loaded, not in a git repo, stale thread ids, `--expect-file` mismatches, out-of-scope files, unencodable filenames — live in the script contract (`scripts/README.md`), along with the notes worth relaying to the user. This skill adds one of its own: **scope resolves to nothing** (see "The script contract" above).
