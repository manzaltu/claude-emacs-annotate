#!/usr/bin/env bash
# Reply to a single pending comment as ANNOTATE_AUTHOR (see lib.sh). The reply
# is added under <parent-comment-id> in the thread identified by <thread-id>;
# the thread's status is NOT touched (the user owns status transitions).
#
# Usage:  respond.sh <thread-id> <parent-comment-id> [--expect-file <path>]
#         echo "reply prose" | respond.sh ...
#
# Reply text is read from stdin (multi-line prose rides through as-is). With
# --expect-file, the operation refuses unless the thread is anchored to that
# file (absolute or project-relative).
#
# Atomic: the API refuses (and nothing is saved) if the parent comment is
# gone, the parent already has a reply, or the thread is no longer open. On
# failure the model should re-run list-pending.sh and try again with a fresh
# item.
#
# Output (JSON):
#   {"replied": true, "thread_id": "th-…", "reply_comment_id": "c-…"}.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

require_jq

USAGE='respond.sh <thread-id> <parent-comment-id> [--expect-file <path>]'
[[ $# -ge 2 ]] || die "usage: $USAGE"
THREAD_ID=$1
PARENT_ID=$2
shift 2
parse_expect_file "$USAGE" "$@"
[[ -n "$THREAD_ID" ]] || die "thread-id is empty"
[[ -n "$PARENT_ID" ]] || die "parent-comment-id is empty"

require_git_repo

TEXT=$(cat)
[[ -n "$TEXT" ]] || die "reply text is empty (read from stdin)"

ARGS=":thread-id $(elisp_quote "$THREAD_ID") \
:parent-comment-id $(elisp_quote "$PARENT_ID") \
:text $(elisp_quote "$TEXT") \
:author $(elisp_quote "$ANNOTATE_AUTHOR")"
ARGS+=$(expect_file_args)

cea_call reply "$ARGS" \
  | jq '{replied: true, thread_id: .thread_id, reply_comment_id: .comment_id}'
