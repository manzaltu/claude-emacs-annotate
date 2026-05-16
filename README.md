# claude-emacs-annotate

A Claude Code plugin that lets Claude leave, clear, and reply to inline annotations on your code in Emacs. Use it to get Claude's reasoning rendered as overlays on the exact lines it's talking about, then have a threaded back-and-forth without ever leaving the buffer. The conversation can start from either side: Claude annotates a diff or works through your custom instructions (a code review, a walkthrough, an audit), or you open a thread on any piece of code and have it answered in place.

The plugin ships its own Emacs package, `claude-emacs-annotate` (under `lisp/`): annotations live in a per-project store and render as the package's overlays, with a store-first design built to survive exactly the things an agent does to your working tree — external file edits under open buffers, silent auto-reverts, and concurrent writers. Positions are anchored to content, not offsets: annotations follow moved code silently, and when their content is rewritten or deleted they're flagged `stale` — never silently dropped — until re-pinned or their content returns. Everything Claude writes — threads it opens and replies it posts in yours — carries the author `claude-code`, and bulk operations key off a thread's *root* author, so threads you opened are never touched.

## Skills

| Command | What it does |
| --- | --- |
| `/annotate [--tag <tag>] <instructions>` | Annotates code per free-form instructions — "review scripts/ for quoting bugs", "explain the tricky parts of src/scheduler.rs", "mark every place that assumes a single tenant". The instructions define which code to examine and what each annotation says; no diff required. Each run's annotations carry a tag (derived from the task, or pinned with `--tag`), so sets from different tasks coexist, and re-running the same instructions updates its set instead of duplicating it. |
| `/annotate-changes [HEAD\|sha\|branch]` | Walks a git diff and leaves one inline annotation per change. Defaults to the merge-base of the current branch. Re-running reconciles against existing annotations rather than wiping them — stale ones are closed, not deleted, so the history survives. |
| `/reply-annotations [--tag <tag>]` | Takes Claude's turn in every thread waiting on it: answers your comments, asks clarifying questions, or makes the requested code changes and replies with what changed. Works on threads from `/annotate`, `/annotate-changes`, and threads you opened anywhere in the code (no prior run needed). With `--tag <tag>`, only threads from that annotation set get a turn. Status transitions stay yours; it never closes a thread. |
| `/clear-annotations [--all \| --tag <tag>]` | Bulk-removes every thread Claude opened (root author `claude-code`) in the current git project. Threads you opened survive, including any replies Claude posted inside them. With `--tag <tag>`, removes a single annotation set (`changes` for the diff set, a task tag for an instruction set). With `--all`, removes every annotation in the project — yours included. |

## Requirements

- Emacs 29.1+ with the bundled `claude-emacs-annotate` package on the load path (see below) and `emacsclient` reachable on `PATH`.
- A running Emacs server (`M-x server-start` or `(server-start)` in your init file).
- `jq` on `PATH` (the skill scripts speak JSON).
- Claude Code.

## Installation

Add the marketplace and install the plugin from inside Claude Code:

```
/plugin marketplace add manzaltu/claude-emacs-annotate
/plugin install claude-emacs-annotate@claude-emacs-annotate
```

Then load the Emacs package from a checkout of this repository. With `use-package`:

```elisp
(use-package claude-emacs-annotate
  :load-path "/path/to/claude-emacs-annotate/lisp"
  :demand t
  :config
  (claude-emacs-annotate-global-mode 1))
```

`claude-emacs-annotate-global-mode` activates annotated buffers automatically (one cheap store-file check per visited file). Bind `claude-emacs-annotate-command-map` to a prefix of your choice for the interactive commands (create, list, next/previous, thread view, re-anchor, ...). The annotations table is `M-x claude-emacs-annotate-list`.

## Annotation storage

Annotations live in one store file per project under `claude-emacs-annotate-directory` (default: `claude-emacs-annotate/` under your Emacs directory via `locate-user-emacs-file` — `~/.emacs.d/` or `~/.config/emacs/` on XDG setups), keyed by project root with project-relative file paths inside. Threads anchor to line ranges plus the region's text and surrounding context, and re-anchor by content matching whenever a file is visited or changes on disk — annotations follow moved code silently and flag as `stale` (instead of drifting or vanishing) when the anchored content changed or is gone. Deletions are merge-safe across concurrent Emacs instances and script runs.

## Display

Annotated regions are tinted (or highlighted — `claude-emacs-annotate-display-style`), with thread text rendered inline in a box below the region by default. `M-x claude-emacs-annotate-toggle-inline` switches between inline boxes and highlight-only; `M-x claude-emacs-annotate-refresh` rebuilds a buffer's overlays from the store if they ever look stale.
