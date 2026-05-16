# claude-emacs-annotate

A Claude Code plugin that lets Claude leave, clear, and respond to inline annotations on your code in Emacs. Use it to get Claude's reasoning rendered as overlays on the exact lines it's talking about, then have a threaded back-and-forth without ever leaving the buffer.

The plugin is built around the [`simply-annotate`](https://github.com/captainflasmr/simply-annotate) Emacs package: annotations are stored in its database, render via its overlays, and are scoped to threads whose root author is `claude-code` so they never collide with annotations you wrote yourself.

## Skills

| Command | What it does |
| --- | --- |
| `/annotate [HEAD\|sha\|branch]` | Walks a git diff and leaves one inline annotation per change. Defaults to the merge-base of the current branch. Re-running reconciles against existing annotations rather than wiping them — stale ones are closed, not deleted, so the history survives. |
| `/annotate-response` | Reads the leaf comments you (or anyone whose author is not `claude-code`) added to open threads and replies to each one. Status transitions stay yours; this skill never closes a thread. |
| `/annotate-clear` | Bulk-removes every annotation authored by `claude-code` in the current git project. User-authored annotations are untouched. |

## Requirements

- Emacs with [`simply-annotate`](https://github.com/captainflasmr/simply-annotate) installed and `emacsclient` reachable on `PATH`.
- A running Emacs server (`M-x server-start` or `(server-start)` in your init file).
- Claude Code.

## Installation

Add the marketplace and install the plugin from inside Claude Code:

```
/plugin marketplace add manzaltu/claude-emacs-annotate
/plugin install claude-emacs-annotate@claude-emacs-annotate
```

## Annotation storage

Annotations live in `~/.emacs.d/.cache/simply-annotations.el` (the default `simply-annotate` database). They are indexed by absolute file path and buffer position, so they follow the file across renames only if you update them yourself.

## Display

If annotations aren't visible inline after a run, cycle the display style with `M-x simply-annotate-cycle-display-style`.
