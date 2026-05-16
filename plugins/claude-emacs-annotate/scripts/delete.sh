#!/usr/bin/env bash
# Delete a single thread, addressed by id. The thread is removed from the
# store (a tombstone is left so the delete survives concurrent merges).
#
# Usage:  delete.sh <thread-id> [--expect-file <path>]
#
# With --expect-file, the operation refuses unless the thread is anchored to
# that file (absolute or project-relative) -- a guard against deleting the
# wrong thread when ids were gathered from a stale listing.
#
# Output (JSON):  {"deleted": true, "thread_id": "th-…"}.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

require_jq

USAGE='delete.sh <thread-id> [--expect-file <path>]'
[[ $# -ge 1 ]] || die "usage: $USAGE"
THREAD_ID=$1
shift
parse_expect_file "$USAGE" "$@"
[[ -n "$THREAD_ID" ]] || die "thread-id is empty"

require_git_repo

ARGS=":thread-id $(elisp_quote "$THREAD_ID")"
ARGS+=$(expect_file_args)

cea_call delete "$ARGS" \
  | jq '{deleted: true, thread_id: .thread_id}'
