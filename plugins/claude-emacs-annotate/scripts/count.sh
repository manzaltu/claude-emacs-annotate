#!/usr/bin/env bash
# Count annotation threads authored by ANNOTATE_AUTHOR (see lib.sh) in the
# current project (git_root). Used after a run to verify the store actually
# persisted what the agent thinks it wrote.
#
# Usage:  count.sh
#
# Output (JSON): the count result object as the API returns it --
#   {
#     "root": "/abs/project/root",
#     "author": "claude-code",
#     "files_with_annotations": 29,
#     "total": 147,
#     "by_status": {"open": 142, "in-progress": 0, "resolved": 0, "closed": 5},
#     "open_by_tag": {"": 3, "changes": 120, "review-quoting": 19},
#     "open_stale": 0,
#     "anchor_states": {"fresh": 145, "stale": 2}
#   }
#
# - `by_status` is seeded with every configured status, so a bucket is always
#   present even at zero. Verify steps compare their reconcile tallies against
#   the "open" bucket (or the relevant `open_by_tag` entry).
# - `open_by_tag` splits the open threads by tag ("" for untagged), so each
#   skill can verify its own annotation set without counting the others'.
# - `open_stale` counts open threads whose anchored content changed or is
#   gone (the reconcile rule edits or closes these).

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

require_jq
require_git_repo

cea_call count ":root-author $(elisp_quote "$ANNOTATE_AUTHOR")" | cea_pp
