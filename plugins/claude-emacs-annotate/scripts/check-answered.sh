#!/usr/bin/env bash
# Mechanical end-of-run check for the reply flow: did every pending comment
# from the start of the run get a reply?
#
# Usage:  list-pending.sh [--tag <tag>] > baseline.json
#         ... reply to every item ...
#         check-answered.sh [--tag <tag>] < baseline.json
#
# Reads the baseline list-pending.sh snapshot (JSON array) from stdin,
# re-queries the current pending set (via list-pending.sh with the SAME tag),
# and classifies by comment_id:
#
#   answered      -- count of baseline comments no longer pending (a reply
#                    landed, or the user closed/deleted the thread mid-run).
#   still_pending -- CURRENT items whose comment_id was in the baseline and is
#                    still pending: these were missed.
#   new_pending   -- CURRENT items whose comment_id was not in the baseline
#                    (the user added them mid-run).
#
# The two arrays carry current list-pending.sh items (fresh line numbers and
# ancestors), so they can be fed straight back into the reply loop.
#
# Pass the SAME --tag the baseline run used, or comments outside the original
# scope get misreported as new_pending.
#
# Output (JSON):
#   {"answered": N, "still_pending": [ …items… ], "new_pending": [ …items… ]}
#
# Exit 0 iff there is nothing left to do (both arrays empty); otherwise exit 1.
# The JSON is printed either way.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

require_jq

TAG=$(parse_optional_tag 'check-answered.sh [--tag <tag>]' "$@")
LIST_ARGS=()
if [[ -n "$TAG" ]]; then
  LIST_ARGS=(--tag "$TAG")
fi

require_git_repo

BASELINE=$(cat)
# Guard the baseline shape up front so a stray blob doesn't slip through as an
# empty set.
if ! printf '%s' "$BASELINE" | jq -e 'type == "array"' >/dev/null 2>&1; then
  die "baseline stdin is not a JSON array (pipe list-pending.sh output in)"
fi

CURRENT=$("$HERE/list-pending.sh" ${LIST_ARGS[@]+"${LIST_ARGS[@]}"})

# Set-partition the current items by whether their comment_id was in the
# baseline, and count baseline ids that have since disappeared.
RESULT=$(jq -n \
  --argjson baseline "$BASELINE" \
  --argjson current "$CURRENT" '
    ($baseline | map(.comment_id)) as $base_ids
    | ($current | map(.comment_id)) as $cur_ids
    | { answered:      ($base_ids - $cur_ids | length),
        still_pending: ($current | map(select(.comment_id as $id | $base_ids | index($id)))),
        new_pending:   ($current | map(select(.comment_id as $id | $base_ids | index($id) | not))) }')

printf '%s\n' "$RESULT"

# Exit 1 when anything remains to do.
printf '%s' "$RESULT" \
  | jq -e '(.still_pending | length) == 0 and (.new_pending | length) == 0' >/dev/null
