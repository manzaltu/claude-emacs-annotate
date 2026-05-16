#!/usr/bin/env bash
# Create one annotation thread authored by ANNOTATE_AUTHOR (see lib.sh).
#
# Usage:  annotate.sh <abs-file> <start-line> <end-line> <tag>
#         annotate.sh --whole-file <abs-file> <tag>
#         echo "prose..." | annotate.sh ...
#
# The annotation text is read from stdin; multi-line prose with quotes and
# backslashes rides through as-is (the whole transport is JSON). The text is
# wrapped in a thread with author=ANNOTATE_AUTHOR, status="open" and
# tags=(<tag>). Reconciliation downstream keys on the author field to find
# skill-authored threads and on the tag to tell annotation sets apart (see
# require_valid_tag in lib.sh).
#
# The region form anchors lines <start-line>..<end-line>; --whole-file creates
# a file-kind anchor spanning the entire file (never goes stale). Anchoring
# reads the file's on-disk content -- no buffer is opened, no file is modified.
#
# Output (JSON):  {"created": true, "thread": {...}}   (the created thread).

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

require_jq

KIND=region
if [[ "${1:-}" == "--whole-file" ]]; then
  KIND=file
  [[ $# -eq 3 ]] || die "usage: annotate.sh --whole-file <abs-file> <tag>"
  FILE=$2
  TAG=$3
else
  [[ $# -eq 4 ]] || die "usage: annotate.sh <abs-file> <start-line> <end-line> <tag>"
  FILE=$1
  SLINE=$2
  ELINE=$3
  TAG=$4
fi

require_git_repo
[[ -f "$FILE" ]] || die "file not found: $FILE"
require_in_scope "$FILE"
if [[ "$KIND" == region ]]; then
  [[ "$SLINE" =~ ^[0-9]+$ ]] || die "start-line must be a positive integer: $SLINE"
  [[ "$ELINE" =~ ^[0-9]+$ ]] || die "end-line must be a positive integer: $ELINE"
  (( SLINE >= 1 && ELINE >= SLINE )) || die "invalid line range: $SLINE..$ELINE"
fi
require_valid_tag "$TAG"

TEXT=$(cat)
[[ -n "$TEXT" ]] || die "annotation text is empty (read from stdin)"

ARGS=":file $(elisp_quote "$FILE") :kind $KIND"
if [[ "$KIND" == region ]]; then
  ARGS+=" :start-line ${SLINE} :end-line ${ELINE}"
fi
ARGS+=" :text $(elisp_quote "$TEXT") :tag $(elisp_quote "$TAG") \
:author $(elisp_quote "$ANNOTATE_AUTHOR")"

cea_call create "$ARGS" \
  | jq '{created: true, thread: .thread}'
