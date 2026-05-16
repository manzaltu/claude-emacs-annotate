# The annotate scripts — shared contract

The annotate skills drive the claude-emacs-annotate Emacs package through
the scripts in this directory. This file is the shared copy of their
contract: locations, invocation rules, the script table, output formats,
failure modes, and the notes worth relaying to the user. The `annotate`
and `annotate-changes` skills reference it and carry only their own
deltas; the reply and clear skills currently document their scripts
inline.

## Location and invocation

All scripts live in the plugin's shared `scripts/` directory — its absolute
path is `${CLAUDE_PLUGIN_ROOT}/scripts`; references like `scripts/batch.sh`
mean that directory. Use that path verbatim — never guess it from the
plugin's name or install layout, and never normalize a relative path in your
head. If it turns out not to exist, resolve the directory deterministically
with `realpath "${CLAUDE_SKILL_DIR}/../../scripts"` instead of probing
likely-looking locations. Invoke the scripts via `Bash` from the project
root. The scripts require `jq` on `PATH` and emit pretty-printed JSON on
stdout (except `diff.sh`, which stays TSV).

## Where to invoke from

**Always `cd` to the project root before invoking any script.** The scripts
scope themselves via `git rev-parse --show-toplevel` of the **current
working directory**, not by any project root passed as an argument. If your
shell is inside a nested git repo (a submodule, a worktree, or any embedded
repo), the scripts silently operate on that nested repo only, and
annotations elsewhere are left untouched. Do not trust a prior shell cwd —
run `cd <project-root>` explicitly before each invocation. The creation
scripts (`annotate.sh`, `batch.sh`) refuse files outside the cwd's project
root, so a wrong cwd fails loudly at create time; the read and clear scripts
have no such tripwire — for them a wrong cwd is silent.

## The scripts

| Script | Purpose | Stdin |
| --- | --- | --- |
| `list-ai.sh` | List every existing skill-authored annotation thread in scope as a JSON array (open and closed, all tags), with thread ids and anchor states. | — |
| `diff.sh [BASELINE]` | Print one TAB-separated record per changed region of the working tree against BASELINE. | — |
| `annotate.sh <abs-file> <start> <end> <tag>` | Create one skill-authored annotation (status `open`) tagged `<tag>`. The `--whole-file <abs-file> <tag>` form creates a whole-file annotation instead (no line range, never goes stale). | annotation text |
| `batch.sh <tag>` | Create many annotations in one Emacs round-trip, all tagged `<tag>`. | JSON array of create specs |
| `edit.sh <thread-id> [--expect-file <abs-file>]` | Replace the prose of an existing annotation in place (does not change its status, identity, tags, or creation metadata; an `edited` stamp is recorded and the anchor is re-pinned against the current code). Always pass `--expect-file` with the file you believe the thread is on — a mismatch aborts instead of editing the wrong thread. | new annotation text |
| `close.sh <thread-id> [--expect-file <abs-file>]` | Set an existing annotation's status to `closed`, preserving its prose. Idempotent. Always pass `--expect-file`. | — |
| `delete.sh <thread-id> [--expect-file <abs-file>]` | Hard-delete a single annotation thread. Reserved for accidents — the normal flow uses `close.sh` instead. | — |
| `count.sh` | Report the persisted totals: `by_status`, per-tag open counts (`open_by_tag`), `open_stale`, `anchor_states`. | — |
| `list-pending.sh [--tag <tag>]` | List every comment awaiting a skill reply (open threads, leaf comments not authored by the skill) as a JSON array. `--tag` scopes to one annotation set. | — |
| `respond.sh <thread-id> <parent-comment-id> [--expect-file <abs-file>]` | Reply to one pending comment as the skill author; never touches thread status. | reply text |
| `check-answered.sh [--tag <tag>]` | End-of-run convergence check for the reply flow: compares a baseline `list-pending.sh` snapshot against the current pending set; exits 1 while anything remains. | baseline JSON array |
| `clear-ai.sh [--all \| --tag <tag>]` | Remove every skill-authored annotation in the current project. `--tag` limits removal to one annotation set; `--all` removes every annotation regardless of author — only on explicit user request. Reset tool — not part of any normal procedure. | — |

## Output formats

`list-ai.sh` output is a JSON array, one object per thread: `{"thread_id",
"file", "abs_file", "status", "tags", "anchor": {"kind", "start_line",
"end_line", "line_count", "state"}, "text"}`. `status` is `open` /
`in-progress` / `resolved` / `closed`; `tags` is the thread's tag array
(skill-created threads carry exactly one); `text` is the root comment's
prose; multi-line prose arrives as real newlines inside the JSON string.
`anchor.kind` is `region` or `file` (whole-file threads have null lines);
`anchor.state` reports how the thread resolves against the file: `fresh`
lines are current and trustworthy (moved code is followed silently), `stale`
means the anchored content changed or is gone — the reported lines are the
last known location. Nothing is ever skipped or dropped from the listing.
Rows are not create specs — when re-creating, build fresh spec objects.

`batch.sh` takes the set's tag as its argument and reads a JSON array of
spec objects: `{"file": "<abs-path>", "start_line": N, "end_line": N,
"text": "..."}` per annotation, or `{"file": "<abs-path>", "kind": "file",
"text": "..."}` for a whole-file annotation. Write the prose as ordinary
JSON strings — real newlines via `\n` in the JSON encoding, no additional
escaping layer. Build the array in memory and pipe it once (a here-doc
works well: `batch.sh <tag> <<'EOF' ... EOF`). New annotations are always
created as threads with `author = "claude-code"`, `status = "open"`, and
the given tag. Per-spec failures (bad line range, missing file) are
collected in the output's `failures` array, never fatal.

`diff.sh` output is `kind<TAB>abs-path<TAB>start-line<TAB>end-line` per
line, where `kind` is `modified` (one line per hunk) or `new` (one line per
added/untracked file, with start=1 and end=line-count).

## Failure modes

- **Emacs server unreachable**: the scripts abort with `cannot reach the
  Emacs server (start it with M-x server-start)`. Relay it, tell the user
  to start Emacs, and abort. Do not attempt any fallback.
- **Package not loaded**: `claude-emacs-annotate is not loaded in Emacs;
  install it and retry` — the Emacs side of the plugin isn't set up. Relay
  and stop.
- **Not in a git repo**: `lib.sh` aborts with `not inside a git
  repository`. Relay this and stop.
- **Stale thread id** (`no thread with id ...`): the store changed since
  your listing — re-run `list-ai.sh` and re-derive the decision for that
  thread.
- **`--expect-file` mismatch** (`thread ... is anchored to ..., not ...`):
  your id-to-file mapping is stale. Re-run `list-ai.sh`; nothing was
  changed.
- **`annotate.sh` or `batch.sh` reports "file is outside the current
  project scope"**: the cwd's project root does not contain the files being
  annotated — almost always a wrong cwd. `cd` to the project root and
  re-run; nothing was created.
- **Filename with TAB or NEWLINE**: `diff.sh` refuses to emit it. Skip
  those files and tell the user.

## Notes for the user

- Annotations render via the claude-emacs-annotate package's own overlays
  when a file is visited; `M-x claude-emacs-annotate-toggle-inline`
  switches between highlight-only and inline thread boxes, and
  `M-x claude-emacs-annotate-refresh` rebuilds a buffer's overlays if they
  ever look stale.
- Annotations persist across Emacs sessions in per-project store files
  under `claude-emacs-annotate-directory`.
- The scripts never open buffers or modify files; annotations anchor to
  on-disk content, so unsaved Emacs edits neither block nor skew a run.
