#!/usr/bin/env bash
# Replace the root comment's text of a single thread, addressed by id. The
# thread's identity (id, status, replies, comment metadata) is preserved; only
# the root comment's prose changes and an `edited` stamp is recorded.
#
# Usage:  edit.sh <thread-id> [--expect-file <path>]
#         echo "new prose" | edit.sh ...
#
# New text is read from stdin (multi-line prose rides through as-is). With
# --expect-file, the operation refuses unless the thread is anchored to that
# file (absolute or project-relative) -- a guard against editing the wrong
# thread when ids were gathered from a stale listing.
#
# Output (JSON):  {"edited": true, "thread": {...}}   (the updated thread).

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

require_jq

USAGE='edit.sh <thread-id> [--expect-file <path>]'
[[ $# -ge 1 ]] || die "usage: $USAGE"
THREAD_ID=$1
shift
parse_expect_file "$USAGE" "$@"
[[ -n "$THREAD_ID" ]] || die "thread-id is empty"

require_git_repo

TEXT=$(cat)
[[ -n "$TEXT" ]] || die "new annotation text is empty (read from stdin)"

ARGS=":thread-id $(elisp_quote "$THREAD_ID") :text $(elisp_quote "$TEXT")"
ARGS+=$(expect_file_args)

cea_call edit-root-text "$ARGS" \
  | jq '{edited: true, thread: .thread}'
