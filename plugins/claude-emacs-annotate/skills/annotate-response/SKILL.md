---
name: annotate-response
description: Use when user types /annotate-response to process their feedback on existing AI-authored annotations and any new threads they opened. Walks every open simply-annotate thread in scope, finds leaf comments not authored by "claude-code", and replies to each one. Status transitions are the user's responsibility — this skill never touches them.
allowed-tools: [Bash, Read, Edit, Write]
---

# /annotate-response — answer the user's comments on annotations

This skill is the response side of `/annotate`. The user has been reading the annotations from a prior `/annotate` run, replying with questions or change requests, and possibly opening new threads of their own. This skill walks the database, finds every comment that's waiting on a response from this skill, and processes them one at a time.

The whole flow is **programmatic**, driven by `list-pending.sh` (find what needs answering) and `respond.sh` (atomically post a reply). The model's job is to read each pending comment, do whatever it asks, and call `respond.sh`. Status transitions on threads are deliberately not part of this skill — the user owns those.

**Announce when you start**: tell the user you're running `/annotate-response` and the scope you're operating in.

## When to use

Only when the user invokes `/annotate-response`. Do not volunteer.

## Where to invoke from

**Always `cd` to the project root before invoking any script in this skill.** The bundled scripts scope themselves via `git rev-parse --show-toplevel` of the **current working directory**, not by any project root passed as an argument. If your shell is inside a nested git repo (a submodule, a worktree, or any embedded repo), the scripts silently operate on that nested repo only, and annotations elsewhere are left untouched. Do not trust a prior shell cwd — run `cd <project-root>` explicitly before each invocation.

## What counts as a "pending" comment

A comment is pending iff all three hold:

1. Its thread's status is `open`. Closed, resolved, and in-progress threads are filtered out — you do not engage with them.
2. Its author is not `claude-code` (it's the user's, not yours).
3. It is a **leaf** in the comment tree — no other comment names it as `parent-id`. "Leaf" is a structural property of the parent-id graph, not a chronological one. Two top-level user comments under the same parent are both leaves; both pending.

These three checks are baked into `list-pending.sh`. You never have to evaluate them yourself.

## Bundled scripts

The scripts live in `scripts/` next to this SKILL.md. Invoke them via `Bash` from inside the project (the scripts self-scope via `git rev-parse --show-toplevel`).

| Script | Purpose | Stdin |
| --- | --- | --- |
| `list-pending.sh` | Print a TSV row for every pending comment in scope. | — |
| `respond.sh <abs-file> <thread-id> <parent-comment-id>` | Atomically post a reply (author = `claude-code`) under the named comment. Refuses if the thread is no longer open, the parent is gone, or the parent already has a child. | reply prose |

`list-pending.sh` output is 7-column TSV, one row per pending comment:

```
<abs-file>\t<start-line>\t<end-line>\t<thread-id>\t<comment-id>\t<author>\t<text>
```

Embedded newlines in `<text>` are encoded as `\n` (matches `batch.sh`'s decoder). Literal TAB in the author or text errors out loudly.

## Procedure

1. **List pending comments**: run `scripts/list-pending.sh` (in this skill's folder) once. Capture all rows.
2. **If 0 rows**: announce nothing-to-do and stop.
3. **For each row**, in order:
   - Read the `<text>` (decode `\n` back to real newlines if needed). Read the file at `<start-line>`–`<end-line>` for context. Then do whatever the comment asks:
     - **Question** → compose an answer.
     - **Code-change request** → make the change via the normal `Edit` tool against the source file. Then compose a reply describing what you changed (and where, with file:line references when useful).
     - **Ambiguous request** → compose a clarifying question that pinpoints the ambiguity.
   - **Reply**: `scripts/respond.sh <abs-file> <thread-id> <parent-comment-id>` (in this skill's folder) piping the reply prose to stdin. The script atomically: locates the thread, verifies the parent is still a leaf and the thread is still open, posts a reply authored as `claude-code`, persists.
   - If `respond.sh` errors (parent already has children, thread no longer open, thread missing), re-run `list-pending.sh` to refresh and continue from the new state. The leaf+open guards in the script protect against drift; refreshing is only needed when one trips.
4. **Verify**: re-run `list-pending.sh` once at the end. It must return 0 rows. If it doesn't, the remaining rows are either ones the loop skipped (real bug — surface to the user) or new comments the user added while you were working (act on them or hand off).
5. **Confirm**: tell the user the breakdown — how many comments answered, how many code edits made, files touched, plus a list of any clarifying questions you raised so they know where to look next.

## Status is the user's responsibility

You never call `close.sh`, never modify `status`, never decide a thread is "resolved". The user reads your replies, decides whether they're satisfied, and flips the status themselves in Emacs. This is by design — it keeps the skill from prematurely declaring conversations finished.

If you have a follow-up question or a comment of your own (e.g. you made a code change but flagged a tradeoff the user should weigh in on), just say so in the reply. The thread stays open; the user sees it on their next pass.

## Reply prose conventions

- Plain prose. No `[AI]` prefix, no marker — authorship is in the thread's `author` field.
- Present tense. Describe what you did or what you found, not what you're about to do.
- Never refer to yourself, "Claude", "the assistant", or the model.
- For code-change replies, include enough specificity that the user can verify without rereading the whole diff: a path, a line number, the new value.
- For "I don't know" or "I need more info" replies, ask one specific question, not a basket of them.
- Same TAB/newline encoding rules as the other annotate scripts: no literal TABs in the text; newlines pass through as real newlines (the script handles encoding for storage).

## Failure modes

- **No pending comments**: list-pending.sh returns empty. Report to user and stop.
- **respond.sh fails with "thread is not open"**: the user (or you on a prior pass) flipped the status while you were composing. Re-run `list-pending.sh` and re-evaluate; the comment may no longer be in scope.
- **respond.sh fails with "comment X already has children"**: someone else replied to the same parent between your `list-pending.sh` call and now. Re-run and pick up the new state.
- **respond.sh fails with "no thread with id X"**: the thread was deleted (or moved). Re-run.
- **list-pending.sh reports stale comments on stderr**: stored positions no longer fit the file. The comments are filtered out of stdout; mention the warning in your final summary.
- **Emacs server unreachable**: `emacsclient` errors. Tell the user to start Emacs (or `M-x server-start`) and stop.
- **Loop fails to converge** (count doesn't drop after `respond.sh`): real bug — surface to the user with the offending row so they can investigate.

## Notes for the user

- Threads opened entirely by you (no `claude-code` comments at all) are picked up just like replies on existing threads — leaf + author≠claude-code + status=open is the only test.
- The skill never runs `close.sh`, `delete.sh`, or `edit.sh`. If you want one of those, use the original `/annotate` flow.
