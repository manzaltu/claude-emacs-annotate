#!/usr/bin/env bash
# List every comment in the current project (git_root) that is pending a
# response from this skill.
#
# Usage:  list-pending.sh [--tag <tag>]
#
# A comment is "pending" iff all three hold:
#   1. Its thread's status == "open" (closed/resolved/in-progress threads are
#      out of scope; the user owns those transitions).
#   2. Its author != ANNOTATE_AUTHOR (it's the user's, not ours).
#   3. It is a leaf of the comment tree (no reply beneath it). "Leaf" is
#      structural, not chronological.
#
# With --tag, only comments in threads carrying that tag are listed (scoping
# the run to one annotation set); comments carry no tags of their own, so the
# filter reads the thread's tags. Default is unscoped.
#
# Output (JSON): an array, one object per pending comment:
#   [
#     {
#       "thread_id": "th-…",
#       "comment_id": "c-…",
#       "author": "Jane Doe",
#       "text": "the comment awaiting a reply",
#       "timestamp": "…Z",
#       "file": "src/main.py",
#       "abs_file": "/abs/root/src/main.py",
#       "anchor": {"kind","start_line","end_line","line_count","state"},
#       "thread_status": "open",
#       "tags": ["review-x"],
#       "ancestors": [{"comment_id","author","text"}, …]  # root→parent chain
#     },
#     ...
#   ]
#
# `ancestors` is the thread history above the pending comment (root first), so
# a reply can see the conversation it is answering. Empty store yields [].

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

require_jq

TAG=$(parse_optional_tag 'list-pending.sh [--tag <tag>]' "$@")

# Pass the agent author explicitly: what counts as "awaiting a reply"
# is part of the wire contract and must not follow a customized
# claude-emacs-annotate-agent-author.
ARGS=":agent-author $(elisp_quote "$ANNOTATE_AUTHOR")"
if [[ -n "$TAG" ]]; then
  ARGS="$ARGS :tag $(elisp_quote "$TAG")"
fi

require_git_repo
ROOT=$(git_root)

cea_call pending "$ARGS" \
  | jq --arg root "$ROOT" '
      [ .pending[]
        | { thread_id: .thread_id,
            comment_id: .comment_id,
            author: .author,
            text: .text,
            timestamp: .timestamp,
            file: .file,
            abs_file: ($root + "/" + .file),
            anchor: .anchor,
            thread_status: .thread_status,
            tags: .tags,
            ancestors: .ancestors } ]'
