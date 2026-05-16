#!/usr/bin/env bash
# List every annotation thread authored by ANNOTATE_AUTHOR (see lib.sh) in the
# current project (git_root).
#
# Usage:  list-ai.sh
#
# Output (JSON): an array, one object per thread, sorted by file then anchor
# start line:
#   [
#     {
#       "thread_id": "th-…",
#       "file": "src/main.py",        # project-relative
#       "abs_file": "/abs/root/src/main.py",
#       "status": "open",             # open | in-progress | resolved | closed
#       "tags": ["review-x"],         # the thread's native tags
#       "anchor": {"kind":"region","start_line":42,"end_line":45,
#                  "line_count":4,"state":"fresh"},
#       "text": "the root comment's prose"
#     },
#     ...
#   ]
#
# - The reconcile step ignores closed threads and considers the rest as
#   candidates for keep/edit/replace.
# - `anchor.state` is `fresh` or `stale` (resolved against the file's
#   on-disk content): `fresh` lines are current and trustworthy; `stale`
#   means the anchored content changed or is gone, and the reported lines
#   are the last known location. Nothing is ever skipped or dropped --
#   every thread appears.
# - `text` is the root comment's prose only (replies are omitted here; use
#   list-pending.sh to see a thread's conversation).
# - Empty store yields [].

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

require_jq
require_git_repo
ROOT=$(git_root)

cea_call query ":root-author $(elisp_quote "$ANNOTATE_AUTHOR")" \
  | jq --arg root "$ROOT" '
      [ .threads[]
        | { thread_id: .id,
            file: .file,
            abs_file: ($root + "/" + .file),
            status: .status,
            tags: .tags,
            anchor: .anchor,
            text: (.comments[0].text // "") } ]
      | sort_by(.file, (.anchor.start_line // 0))'
