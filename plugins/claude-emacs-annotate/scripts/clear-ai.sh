#!/usr/bin/env bash
# Remove annotation threads from the current project (git_root).
#
# Usage:  clear-ai.sh [--all | --tag <tag>]
#
# - Default (no flag): removes every thread whose root comment author is
#   ANNOTATE_AUTHOR (see lib.sh). Threads rooted by other authors survive
#   intact -- even when they contain ANNOTATE_AUTHOR replies.
# - --tag <tag>: removes only ANNOTATE_AUTHOR threads carrying that tag (one
#   annotation set), leaving other skill-authored sets intact.
# - --all: drops the author filter -- EVERY thread in the project is removed,
#   including ones the user opened. Reserved for an explicit user request.
#
# Removal happens straight in the store; no buffers are opened and no files
# are touched. Threads in other projects are never affected.
#
# Output (JSON):
#   {"cleared": true, "mode": "author"|"tag"|"all", "tag": "<tag>"|null,
#    "root": "/abs/project/root", "removed": N}

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

require_jq

USAGE="usage: clear-ai.sh [--all | --tag <tag>]"
ARGS=":root-author $(elisp_quote "$ANNOTATE_AUTHOR")"
if [[ $# -gt 0 ]]; then
  case "$1" in
    --all)
      ARGS=":all t"
      shift
      ;;
    --tag)
      [[ $# -ge 2 ]] || die "$USAGE"
      require_valid_tag "$2"
      ARGS=":root-author $(elisp_quote "$ANNOTATE_AUTHOR") :tag $(elisp_quote "$2")"
      shift 2
      ;;
    *) die "$USAGE" ;;
  esac
fi
[[ $# -eq 0 ]] || die "$USAGE"

require_git_repo
ROOT=$(git_root)

cea_call clear "$ARGS" \
  | jq --arg root "$ROOT" \
      '{cleared: true, mode: .mode, tag: .tag, root: $root, removed: .removed}'
