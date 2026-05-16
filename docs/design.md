# claude-emacs-annotate — design

Threaded, line-anchored code annotations with a per-project store,
built to be driven programmatically by the bundled annotation skills
while keeping a first-class interactive UI.

## Why store-first

An annotation backend driven by an agent has to survive exactly the
things an agent does to a working tree: files rewritten on disk under
open buffers, silent reverts (`global-auto-revert-mode`), and
concurrent writers racing interactive sessions. Any design where live
buffer state is the source of truth loses data on those paths —
whatever destroys an overlay before a write destroys the annotation.

The model here:

1. **The store is the source of truth.** One in-memory store per
   project (`claude-emacs-annotate-store.el`), mirrored to one
   database file per project under `claude-emacs-annotate-directory`.
   Every mutation writes through immediately and atomically (temp
   file + rename in the same directory).
2. **Overlays are a view.** They carry a thread id and nothing else
   (`claude-emacs-annotate-view.el`). Losing them can never lose
   data, only position freshness.
3. **Anchors, not offsets.** Threads record a line range plus the
   region's exact text, a hash, and a few context lines
   (`claude-emacs-annotate-anchor.el`). Whenever a buffer attaches,
   positions are re-derived by content matching — never trusted from
   storage.
4. **Nothing is ever silently dropped.** Anchors resolve to one of
   two states: `fresh` (content located — at the recorded lines,
   found elsewhere, or whitespace-normalized — and silently followed)
   or `stale` (content changed or gone). Stale is a latch: it is
   badged, listed, and persists until the original content returns
   (automatic rescue), the thread is re-pinned with
   `claude-emacs-annotate-reanchor`, or its root text is edited
   against the current code.

## Module map

| Module | Responsibility |
| --- | --- |
| `claude-emacs-annotate-core.el` | Options, faces, error taxonomy, ids/timestamps, thread/comment constructors and accessors, comment trees, validation. Pure. |
| `claude-emacs-annotate-anchor.el` | Anchor capture (from buffers or straight from disk) and the resolve procedure below. |
| `claude-emacs-annotate-store.el` | Per-project store, roots and project detection, atomic write-through, mtime guard + merge, tombstones, file watcher, change events. |
| `claude-emacs-annotate-api.el` | The programmatic contract: explicit roots, no buffer dependence, typed errors, `:expect-file` preconditions, JSON transport. |
| `claude-emacs-annotate-view.el` | Buffer minor mode, overlays, tint/highlight styles, inline thread boxes, the flush engine and revert brackets. |
| `claude-emacs-annotate-table.el` | Project-wide `tabulated-list` of threads, rendered from the store with anchors resolved against on-disk content. |
| `claude-emacs-annotate-thread.el` | Per-thread view buffers and commit-style reply/edit buffers (no singleton state). |
| `claude-emacs-annotate.el` | Entry point: globalized mode, DWIM command, command map. |

## On-disk schema (version 1)

One `.eld` file per project (root sanitized `!`→`!!`, `/`→`!`),
written with `print-length`/`print-level` bound to nil:

```elisp
(:version 1 :root "/abs/root"
 :threads ((:id "th-…" :file "src/a.el" :created "…Z" :updated "…Z"
            :status "open" :priority "normal" :tags ("changes")
            :anchor (:kind region              ; region | file
                     :start-line 42 :end-line 45 :line-count 4
                     :text "…"                 ; nil when capped
                     :text-cap nil             ; (:first … :last …) for huge regions
                     :text-hash "sha1"
                     :ws-hash nil              ; sha1 of normalized text, capped only
                     :before ("…") :after ("…")
                     :state fresh)             ; fresh|stale
            :comments ((:id "c-…" :parent-id nil :author "…"
                        :timestamp "…Z" :text "…" :edited nil) …)) …)
 :tombstones ((:id "th-…" :deleted "…Z") …))
```

Timestamps are UTC ISO-8601 with milliseconds and sort
lexicographically; `:updated` is the merge's last-writer-wins key and
is strictly increasing per process. Strings are property-free by
construction (`substring-no-properties` on every ingest path).

## Anchor resolution

On every attach (find-file, after-revert, external reload), per
thread:

1. `:kind file` → fresh, spans the buffer.
2. Exact text at the recorded lines (capped anchors verify head +
   tail blocks and the hash) → **fresh**.
3. Exact line-aligned match elsewhere → nearest to the recorded line,
   context score as tiebreak, then lowest line → **fresh**, silently
   followed to the new lines.
4. Whitespace-normalized match → **fresh**, followed.
5. Context blocks located with different content between them
   (one-sided allowed, clamped by line count) → **stale**; the
   located lines are adopted but the recorded content is preserved —
   recapturing it would make the next resolve bless the changed
   content.
6. Otherwise → **stale**: record untouched, lines clamped for
   display only.

Whitespace-only anchor text never matches in steps 3–4 (any blank
line would do), so blank-line anchors are placed by context or not at
all.

Stale is a latch. Fresh resolutions are adopted and persisted at
attach; a flush from a live buffer recaptures fresh threads' extents
(typing under an attached overlay is watched, so it blesses), while
stale threads only drift their lines — the latch clears via rescue
(the recorded content reappears), `claude-emacs-annotate-reanchor`,
or an `edit-root-text` that re-pins against the current code when
the spot is still locatable.

## Flush engine and hooks

Flush recomputes each overlay's line range; fresh threads recapture
their anchor, stale threads keep content and state. Zero-width
overlays mark their thread stale. Deltas land in one batched
`anchors-updated` mutation; no change means no write.

| Trigger | Action |
| --- | --- |
| `find-file-hook` (global mode) | store-file stat → enable mode + attach |
| `after-change-functions` | flag buffer, arm one-shot idle timer |
| idle timer | flush pending buffers |
| `before-save-hook`, `kill-buffer-hook` | synchronous flush |
| `before-revert-hook` | synchronous flush, then detach |
| `after-revert-hook` | attach = full content re-resolution |
| `store-before-mutate-hook` | flush the project's pending buffers |
| `changed-hook` | view/table/thread buffers refresh |
| file-notify (directory watch) | debounce → own-write check → merge + `reloaded` |
| `kill-emacs-hook` | flush everything pending |

`global-auto-revert-mode` reverts run the hook brackets
(`preserve-modes` keeps the minor mode alive); manual reverts recover
through the globalized mode's `after-change-major-mode-hook`
re-enable.

## Concurrency

Before every write the file's mtime/size are compared with the values
cached at the last read; a mismatch merges disk state in first:

- per thread id, the newer of live record and tombstone wins;
- a timestamp tie goes to the tombstone (deletion is deliberate);
  live-vs-live ties break deterministically on the serialized form;
- comments are unioned by id, so concurrent replies all survive;
- tombstones make `clear`/`delete` merge-safe (a stale writer cannot
  resurrect them) and are garbage collected after
  `claude-emacs-annotate-tombstone-ttl-days`.

The mtime guard is optimistic — a write can land between another
writer's read and rename. Convergence relies on the losing writer's
next refresh (watcher-driven in live sessions) merging and
re-persisting its state; no cross-process lock is taken.

## Wire contract

`(claude-emacs-annotate-api-call OP ROOT ARGS OUT-FILE)` never
signals for operation errors; it writes
`{"ok":true,"result":…}` or
`{"ok":false,"error":{"type":…,"message":…}}` to OUT-FILE. Keys are
snake_case; arrays are never null. Ops: `create`, `create-batch`
(specs via `:specs-file`), `reply`, `edit-root-text`, `set-status`,
`delete`, `query`, `pending` (leaf comments in open threads not
authored by the agent author, with root→parent ancestor chains),
`count`, `clear`. Error types: `not_found`, `conflict`,
`expectation_failed`, `invalid`, `io`, `schema`, `internal`. All
mutations accept `:expect-file` as an anchoring precondition.

The exact shapes are pinned by the ERT suite
(`test/claude-emacs-annotate-api-test.el`); change them deliberately
or not at all.

## Testing

`make all` byte-compiles warning-free, runs checkdoc, and executes
the ERT suites, including batch simulations of the production failure
modes: external edit + silent revert, revert with unsaved edits,
the stale latch (zero-width overlays, visit-and-kill survival) and
its rescue, divergent-writer merges, clear-resurrection, and
file-watcher delivery of atomic renames.
