#!/usr/bin/env bash
# Set a thread's status to "closed" so it stays in the store as inert history
# rather than being deleted. A closed thread stops participating in subsequent
# reconcile passes (list-ai.sh still emits it, with status=closed; the
# procedure ignores closed threads when matching). The prose is preserved.
#
# Usage:  close.sh <thread-id> [--expect-file <path>]
#
# With --expect-file, the operation refuses unless the thread is anchored to
# that file (absolute or project-relative). Re-closing an already-closed
# thread is a no-op; the previous status rides back in the output so the
# caller can see if something was odd.
#
# Output (JSON):  {"closed": true, "previous_status": "open", "thread": {...}}.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

require_jq

USAGE='close.sh <thread-id> [--expect-file <path>]'
[[ $# -ge 1 ]] || die "usage: $USAGE"
THREAD_ID=$1
shift
parse_expect_file "$USAGE" "$@"
[[ -n "$THREAD_ID" ]] || die "thread-id is empty"

require_git_repo

ARGS=":thread-id $(elisp_quote "$THREAD_ID") :status \"closed\""
ARGS+=$(expect_file_args)

cea_call set-status "$ARGS" \
  | jq '{closed: true, previous_status: .previous_status, thread: .thread}'
