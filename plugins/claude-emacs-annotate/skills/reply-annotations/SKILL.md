---
name: reply-annotations
description: Use when user types /reply-annotations to hold line-anchored conversations with the user through claude-emacs-annotate threads — replies they left on AI-authored annotations as well as threads they opened anywhere in the code. Each comment awaiting a response is handled as if typed into the chat prompt (answered, questioned, or acted on with code changes), and a reply is always posted back in the thread. With --tag, the run is scoped to threads carrying that tag (one annotation set); by default every pending comment is in scope. Status transitions are the user's responsibility — this skill never touches them.
argument-hint: "[--tag <tag>]"
allowed-tools: [Bash, Read, Edit, Write]
---

# /reply-annotations — take your turn in the user's annotation threads

Annotation threads are a conversation interface: each open thread is a discussion with the user, pinned to specific lines of code. A comment that isn't yours and that nothing has answered yet is the user's turn, waiting on you. This skill takes your turn, comment by comment.

Pending comments arrive in two forms, and both are handled identically:

- **Replies on existing threads** — typically feedback on annotations from a prior `/annotate` or `/annotate-changes` run: questions, change requests, pushback.
- **Threads the user opened themselves** — a fresh annotation at any position in any file in scope, with no prior involvement from this skill. Every new annotation is an open thread, so to the scripts these look exactly like the first kind: an open thread whose leaf comment isn't ours.

A prior annotation run is **not** a prerequisite. The only test for whether a comment gets a turn is leaf + author≠`claude-code` + status=open — who opened the thread never matters.

**Handle each comment exactly as if the user had typed it into the chat prompt with the annotated lines attached as context.** Everything you would do in chat is in scope: answer, explain, push back, ask for the detail you're missing, or change the code — and a change goes wherever the request leads, not just inside the annotated range. The result should be indistinguishable from a chat exchange; only the interface differs.

Two bookkeeping rules distinguish this from chat, and both are absolute:

1. **Your turn always ends with a reply in the thread.** Code edits don't speak for themselves: without a reply, the user's comment remains the thread's leaf and the next `/reply-annotations` run treats it as unanswered. After an edit, the reply is a short note on what changed and where; when all you have is a question, the question is the reply.
2. **You never touch thread status.** Only the user decides a conversation is over (see "Status is the user's responsibility" below).

The flow is **programmatic**, driven by `list-pending.sh` (find what needs answering) and `respond.sh` (atomically post a reply). Your job is to read each pending comment, do the work it calls for, and call `respond.sh`.

**Announce when you start**: tell the user you're running `/reply-annotations` and the scope you're operating in — the whole project, or the annotation set named by `--tag`.

## When to use

Only when the user invokes `/reply-annotations` (with or without the argument). Do not volunteer.

## The --tag argument

`$ARGUMENTS` is either empty or `--tag <tag>`:

| Input | Meaning |
| --- | --- |
| *(empty)* | Every pending comment in the project — any thread, tagged or not. |
| `--tag <tag>` | Only pending comments in threads carrying that tag: one annotation set's conversations (`changes` for the `/annotate-changes` set, a task tag for a `/annotate` set). |

The tag is a property of the **thread**, stamped when the annotating skill opened it — individual comments carry no tags. So the filter selects conversations by where they started: a user reply deep inside a tagged thread is in scope, while a thread the user opened themselves (which carries no tag) is not. Filtering happens inside `list-pending.sh`; you never evaluate it yourself.

## Where to invoke from

**Always `cd` to the project root before invoking any script in this skill.** The bundled scripts scope themselves via `git rev-parse --show-toplevel` of the **current working directory**, not by any project root passed as an argument. If your shell is inside a nested git repo (a submodule, a worktree, or any embedded repo), the scripts silently operate on that nested repo only, and annotations elsewhere are left untouched. Do not trust a prior shell cwd — run `cd <project-root>` explicitly before each invocation.

## What counts as a "pending" comment

A comment is pending iff all three hold:

1. Its thread's status is `open`. Closed, resolved, and in-progress threads are filtered out — you do not engage with them.
2. Its author is not `claude-code` (it's the user's, not yours).
3. It is a **leaf** in the comment tree — no other comment names it as `parent-id`. "Leaf" is a structural property of the parent-id graph, not a chronological one. Two top-level user comments under the same parent are both leaves; both pending.

The root comment of a thread the user opened themselves passes all three checks — it is a leaf until someone replies to it. That is how user-opened threads enter the flow without any special-casing.

These three checks are baked into `list-pending.sh`; with `--tag`, the thread-carries-the-tag check is baked in too. You never have to evaluate any of them yourself.

## Bundled scripts

The scripts live in the plugin's shared `scripts/` directory — its absolute path is `${CLAUDE_PLUGIN_ROOT}/scripts`; references like `scripts/list-pending.sh` below mean that directory. Use that path verbatim — never guess it from the plugin's name or install layout, and never normalize a relative path in your head. If it turns out not to exist, resolve the directory deterministically with `realpath "${CLAUDE_SKILL_DIR}/../../scripts"` instead of probing likely-looking locations. Invoke the scripts via `Bash` from inside the project (the scripts self-scope via `git rev-parse --show-toplevel`). The scripts require `jq` on `PATH` and emit pretty-printed JSON on stdout.

| Script | Purpose | Stdin |
| --- | --- | --- |
| `list-pending.sh [--tag <tag>]` | Print a JSON array with one object per pending comment in scope. With `--tag`, only comments in threads carrying that tag. | — |
| `respond.sh <thread-id> <parent-comment-id> [--expect-file <abs-file>]` | Atomically post a reply (author = `claude-code`) under the named comment. Refuses if the thread is no longer open, the parent is gone, or the parent already has a child. | reply prose |
| `check-answered.sh [--tag <tag>]` | Mechanical end-of-run check: reads the step-1 baseline JSON on stdin, re-queries the pending set, prints `answered` / `still_pending` / `new_pending`, and exits 0 only when nothing is left to do. Must be given the same `--tag` as the baseline run. | baseline JSON |

`list-pending.sh` output is a JSON array, one object per pending comment:

```json
{
  "thread_id": "th-…", "comment_id": "c-…",
  "author": "Jane Doe",
  "text": "the comment awaiting a reply",
  "timestamp": "…Z",
  "file": "src/main.py", "abs_file": "/abs/root/src/main.py",
  "anchor": {"kind": "region", "start_line": 42, "end_line": 45,
             "line_count": 4, "state": "fresh"},
  "thread_status": "open", "tags": ["review-x"],
  "ancestors": [{"comment_id": "c-…", "author": "claude-code",
                 "text": "the annotation being replied to"}]
}
```

Multi-line comment text arrives as real newlines inside the JSON strings — there is no extra escaping layer. `ancestors` is the conversation above the pending comment (root first, up to its parent), so you see what the user is responding to without extra lookups; a user-opened thread's root comment has an empty `ancestors` array. `comment_id` is what you hand to `respond.sh` as `<parent-comment-id>`.

`check-answered.sh` output is `{"answered": N, "still_pending": [...], "new_pending": [...]}` where the arrays carry **current** pending items (fresh line numbers and ancestors) classified by `comment_id`: `still_pending` are baseline comments your loop missed — a bug; `new_pending` are comments the user added while you worked. Exit 0 iff both arrays are empty.

## Procedure

1. **List pending comments**: run `scripts/list-pending.sh $ARGUMENTS` (in the shared scripts directory) once and save its output verbatim to a scratch file — it is both your work list and the baseline for the final check.
2. **If the array is empty**: announce nothing-to-do and stop.
3. **For each item**, in order:
   - Read `.text` and the `ancestors` chain for the conversation so far. Read the file at `anchor.start_line`–`anchor.end_line` plus whatever surrounding context you need — for the root comment of a user-opened thread there is no earlier exchange to lean on, so the code itself is the context. When `anchor.state` is `stale`, the code the thread pointed at changed or is gone — still take the turn, and note it when it matters to the answer. Then act as you would in chat:
     - **You can answer** → compose the answer.
     - **You can do what's asked and have no open questions** → make the change with the normal editing tools, following the request wherever it leads — the annotated range anchors the discussion, it does not bound the edit. Then compose a short reply saying what changed and where (file:line references when useful).
     - **You're missing something** → make no edit; ask the one clarifying question that unblocks you, and act on the next round once the user answers.
   - **Reply**: `scripts/respond.sh <thread_id> <comment_id> --expect-file <abs_file>` (in the shared scripts directory) piping the reply prose to stdin. The script atomically verifies the parent is still a leaf and the thread is still open, posts a reply authored as `claude-code`, and persists. Every processed comment ends with a reply — an edit without one is a silent change that leaves the user's comment as the leaf, and the next run treats it as unanswered.
   - If `respond.sh` errors (parent already has a reply, thread no longer open, thread missing), re-run `list-pending.sh` to refresh and continue from the new state. The leaf+open guards in the script protect against drift; refreshing is only needed when one trips.
4. **Verify mechanically**: run `scripts/check-answered.sh $ARGUMENTS` (the same `--tag` scope as step 1, or none) with the saved baseline on stdin. `jq '.still_pending | length'` and `jq '.new_pending | length'` classify what's left; the script exits 0 only when nothing is. On failure, treat the printed items as a fresh work list: repeat step 3 on them, then run the check again. Do not end the run while `check-answered.sh` fails; mention any `still_pending` incident in the final summary.
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
- Write plain multi-line prose; the JSON transport carries it as-is with no extra encoding rules.

## Failure modes

- **No pending comments**: `list-pending.sh` returns `[]`. Report to user and stop.
- **respond.sh fails with "thread ... is not open"**: the user (or you on a prior pass) flipped the status while you were composing. Re-run `list-pending.sh` and re-evaluate; the comment may no longer be in scope.
- **respond.sh fails with "comment ... already has a reply"**: someone else replied to the same parent between your `list-pending.sh` call and now. Re-run and pick up the new state.
- **respond.sh fails with "no thread with id ..."**: the thread was deleted. Re-run.
- **`--expect-file` mismatch** (`thread ... is anchored to ..., not ...`): your listing is stale. Re-run `list-pending.sh`; nothing was posted.
- **A pending item has `anchor.state: "stale"`**: not an error — the referenced code changed or is gone. Reply normally.
- **Emacs server unreachable**: the scripts abort with `cannot reach the Emacs server (start it with M-x server-start)`. Tell the user to start Emacs and stop.
- **Package not loaded**: `claude-emacs-annotate is not loaded in Emacs; install it and retry` — the Emacs side of this plugin isn't set up. Relay and stop.
- **Loop fails to converge** (`check-answered.sh` keeps reporting the same `still_pending` item after you replied to it): real bug — surface to the user with the offending item so they can investigate.

## Notes for the user

- To start a conversation about any piece of code, just open an annotation thread on it (`M-x claude-emacs-annotate-dwim` on a line or region) — no prior annotation run needed. As long as the thread is open and its latest comment is yours, the next `/reply-annotations` pass picks it up.
- The skill never runs `close.sh`, `delete.sh`, or `edit.sh`. Those belong to the `/annotate` and `/annotate-changes` flows.
