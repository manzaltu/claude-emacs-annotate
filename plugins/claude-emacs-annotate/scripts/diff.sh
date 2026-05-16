#!/usr/bin/env bash
# Emit normalized diff records for the /annotate-changes skill (also used by
# /annotate when its instructions scope the work by a set of changes).
#
# Usage:  diff.sh [BASELINE]
#   BASELINE: empty/branch → merge-base(primary, HEAD); ref/sha → that commit.
#
# Output: one record per line, TAB-separated, in this format:
#   modified<TAB><abs-path><TAB><start-line><TAB><end-line>
#   new<TAB><abs-path><TAB><start-line><TAB><end-line>
#
# `modified` rows come from `git diff --unified=0` hunk headers (one per hunk).
# `new` rows come from (a) `git diff` "new file mode" entries and (b)
# `git ls-files --others --exclude-standard`. For new files the script emits a
# single record spanning lines 1..N; the caller is expected to subdivide.
#
# Filenames with embedded TAB or NEWLINE will fail loudly (rare in practice;
# we'd rather fail than silently mangle them).

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

require_git_repo
ROOT=$(git_root)
BASELINE_ARG=${1:-}
REF=$(resolve_baseline "$BASELINE_ARG")

reject_weird() {
  case "$1" in
    *$'\t'*|*$'\n'*)
      die "filename contains TAB or NEWLINE, refusing: $1"
      ;;
  esac
}

emit_modified_hunks_for_file() {
  local relpath=$1
  local oldpath=${2:-}
  reject_weird "$relpath"
  [[ -n "$oldpath" ]] && reject_weird "$oldpath"
  local abs="$ROOT/$relpath"
  # For renames/copies the source path must be in the pathspec too, or git
  # cannot pair the two sides and reports the file as fully added — turning
  # a 3-line edit in a renamed file into one whole-file hunk.
  # Pure-deletion hunks have +c,0 in the header; we still emit a 1-line
  # annotation at +c so the user has something to attach prose to.
  git diff --no-color --unified=0 --find-renames --find-copies "$REF" \
      -- "$relpath" ${oldpath:+"$oldpath"} \
    | awk -v abs="$abs" '
        /^@@ / {
          # "@@ -a,b +c,d @@" or "@@ -a,b +c @@" (when d == 1)
          n = split($0, parts, " ")
          plus = parts[3]                  # "+c,d" or "+c"
          sub(/^\+/, "", plus)
          if (index(plus, ",")) {
            split(plus, cd, ",")
            c = cd[1] + 0
            d = cd[2] + 0
          } else {
            c = plus + 0
            d = 1
          }
          if (d == 0) { start = c; end = c }
          else        { start = c; end = c + d - 1 }
          if (start < 1) start = 1
          if (end < start) end = start
          printf "modified\t%s\t%d\t%d\n", abs, start, end
        }
      '
}

emit_new_file_record() {
  local abspath=$1
  reject_weird "$abspath"
  local lines
  if [[ -f "$abspath" ]]; then
    # awk's NR counts records (lines), correctly handling files that lack
    # a trailing newline -- wc -l counts \n characters and would undercount
    # by one for unterminated files.
    lines=$(awk 'END{print NR}' "$abspath")
    [[ -z "$lines" || "$lines" == "0" ]] && lines=1
  else
    lines=1
  fi
  printf 'new\t%s\t1\t%d\n' "$abspath" "$lines"
}

# 1) Tracked-file changes: walk diff status, split modified vs new.
#    `-z` makes paths NUL-separated; status is one byte (A/M/D/R/T...).
while IFS= read -r -d '' status_field && IFS= read -r -d '' path_field; do
  case "$status_field" in
    A*) emit_new_file_record "$ROOT/$path_field" ;;
    M*|T*) emit_modified_hunks_for_file "$path_field" ;;
    D*) : ;;  # deleted — nothing in working tree to annotate
    R*|C*)
        # rename/copy: status_field is "R<score>"/"C<score>", followed by
        # OLD then NEW path. Read the new path (we already consumed the
        # old one as path_field); pass the old path too so the hunk diff
        # can pair the rename.
        IFS= read -r -d '' new_path
        emit_modified_hunks_for_file "$new_path" "$path_field"
        ;;
    *) : ;;
  esac
done < <(git diff -z --name-status --find-renames --find-copies "$REF" --)

# 2) Untracked files (not in git diff at all)
while IFS= read -r -d '' u; do
  [[ -z "$u" ]] && continue
  emit_new_file_record "$ROOT/$u"
done < <(git ls-files -z --others --exclude-standard)
