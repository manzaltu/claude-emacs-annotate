#!/usr/bin/env bash
# Create many annotation threads authored by ANNOTATE_AUTHOR (see lib.sh) in a
# single Emacs round-trip. Much faster than one annotate.sh per record and
# gathers every per-spec error in one pass.
#
# Usage:  batch.sh <tag>
#
# Reads a JSON array of annotation specs from stdin:
#   [
#     {"file":"/abs/f", "start_line":12, "end_line":14, "text":"prose…"},
#     {"file":"/abs/g", "kind":"file",  "text":"whole-file note"},
#     ...
#   ]
# Each spec needs `file` and `text`. `start_line`/`end_line` are required for
# the default region kind; `kind:"file"` makes a whole-file anchor (no lines).
# Multi-line text rides through natively -- no escaping. The tag is the
# script's argument, injected into every spec, so a batch always writes one
# annotation set and can never mix sets by accident.
#
# Anchoring reads each file's on-disk content; no buffer is opened, no file is
# modified. A spec that fails (bad line range, missing file, …) is collected
# in `failures`, never fatal -- the batch always exits 0.
#
# Output (JSON):
#   {"created": N, "failed": N, "files_touched": N,
#    "threads":  [{"thread_id","file","start_line","end_line"}, …],
#    "failures": [{"file","start_line","end_line","error"}, …]}
#
# An empty array (or empty/whitespace stdin) short-circuits to all-zeros
# without touching Emacs.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

require_jq

[[ $# -eq 1 ]] || die "usage: batch.sh <tag>"
TAG=$1
require_valid_tag "$TAG"
require_git_repo

RAW=$(cat)

# The all-zeros result both no-work short-circuits emit; one copy so the
# wire shape cannot drift between them.
emit_empty_result() {
  printf '{"created":0,"failed":0,"files_touched":0,"threads":[],"failures":[]}\n' | cea_pp
  exit 0
}

# Empty / whitespace-only / empty-array input: nothing to do, no Emacs.
if [[ -z "${RAW//[[:space:]]/}" ]]; then
  emit_empty_result
fi

# Structurally validate: must be a JSON array. jq's error text rides into the
# die message so a malformed payload is diagnosable.
if ! err=$(printf '%s' "$RAW" | jq -e 'if type == "array" then . else error("not an array") end' 2>&1 >/dev/null); then
  die "stdin is not a JSON array of annotation specs: $err"
fi

# Empty array short-circuits too.
if [[ "$(printf '%s' "$RAW" | jq 'length')" -eq 0 ]]; then
  emit_empty_result
fi

# Scope check over the unique files named in the specs, before any Emacs work.
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  require_in_scope "$f"
done < <(printf '%s' "$RAW" | jq -r '.[].file // empty' | sort -u)

# Inject the tag and author into every spec, normalizing kind to a string, and
# write the result to a temp specs file the API reads via :specs-file. Keys are
# snake_case per the wire contract.
SPECS=$(cea_mktemp)
printf '%s' "$RAW" \
  | jq --arg tag "$TAG" --arg author "$ANNOTATE_AUTHOR" \
      '[ .[] | {file: .file,
                start_line: .start_line,
                end_line: .end_line,
                kind: (.kind // "region"),
                text: .text,
                tag: $tag,
                author: $author} ]' > "$SPECS"

# create-batch returns created/failed/threads/failures; add files_touched, the
# count of distinct files among the created threads.
cea_call create-batch ":specs-file $(elisp_quote "$SPECS")" \
  | jq '{created: .created,
         failed: .failed,
         files_touched: ([.threads[].file] | unique | length),
         threads: .threads,
         failures: .failures}'
